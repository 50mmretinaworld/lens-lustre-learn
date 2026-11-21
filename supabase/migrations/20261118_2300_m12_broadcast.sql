-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2300 · M12 — Broadcast: an admin message into every chosen member's message box
-- Owner order 21 Nov 2026: "admin sends a message with image, emoji, web link to all members' message
-- boxes; it reaches them automatically; delivered / failed / read per batch and per member".
--
--   How it runs (never in one go): "send" snapshots the audience into message_broadcast_recipients, cuts it
--   into batches of 500 (default) and queues one job per batch on the JOB ENGINE, one minute apart. Each
--   batch job puts the message into 500 boxes (one chat per member with the sending admin, who shows as the
--   brand "50mm Retina World"), then the next batch runs. A message is NEVER stored twice for a member (a
--   fixed message id per broadcast + member), so a retry is safe. A failed batch retries on the engine's own
--   back-off; a member who cannot be reached is recorded with the reason.
--   Push: each stored message queues the normal message push (M3) — sender = brand, never the text — unless
--   the broadcast is saved with push off. Pause / resume / cancel / retry failed / withdraw (removes the
--   message from every box, in batches) are admin functions.
--   Reads for the admin page: admin_message_broadcasts (list + filter counts), _report (totals + batches),
--   _recipients (per member: delivered / failed / read, search, paging). "Read" = the member opened the chat
--   (their last_read_at is at or after the message).
--   Audience = the push centre's audiences (all · active 7/30 days · role · badge · chosen members ≤ 500),
--   only members who can receive messages (active, not under review), never the sender.
--
--   message_attachments_path_once (UNIQUE storage_path) is replaced by a plain index: one uploaded broadcast
--   picture is shared by every copy. Members still cannot re-send a path that is already used (the send door
--   checks it, MSG-025).
--
-- Rollback: supabase/rollback/20261118_2300_m12_broadcast_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2300_m12_broadcast.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.admin_view_inbox(uuid,text,integer,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'M12-PRE-001: M11 (20261118_2200) is not applied';
  END IF;
  IF to_regprocedure('public.push_audience_members(jsonb)') IS NULL OR to_regprocedure('public.job_enqueue(text,jsonb,text,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'M12-PRE-002: the push centre audiences or the job engine are missing';
  END IF;
  IF to_regclass('public.message_broadcasts') IS NOT NULL THEN
    RAISE EXCEPTION 'M12-PRE-003: message_broadcasts already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. one broadcast picture is shared by every copy ───────────────────────
ALTER TABLE public.message_attachments DROP CONSTRAINT message_attachments_path_once;
-- P28: message_attachments · a fraction of messages · finding the message a picture belongs to (photo link check, send-door reuse check)
CREATE INDEX message_attachments_path_idx ON public.message_attachments (storage_path);

-- ── 2. tables ──────────────────────────────────────────────────────────────
CREATE TABLE public.message_broadcasts (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title              text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
  body               text NOT NULL DEFAULT '' CHECK (char_length(body) <= 4000),
  photos             jsonb NOT NULL DEFAULT '[]'::jsonb,
  audience           jsonb NOT NULL DEFAULT '{"kind": "all"}'::jsonb,
  push               boolean NOT NULL DEFAULT true,
  sender_id          uuid NOT NULL,
  status             text NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft', 'scheduled', 'sending', 'paused', 'done', 'cancelled', 'withdrawn')),
  batch_size         integer NOT NULL DEFAULT 500 CHECK (batch_size BETWEEN 50 AND 1000),
  batch_gap_seconds  integer NOT NULL DEFAULT 60 CHECK (batch_gap_seconds BETWEEN 10 AND 3600),
  send_at            timestamptz,
  total_members      integer CHECK (total_members IS NULL OR total_members >= 0),
  created_by         uuid NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  started_at         timestamptz,
  finished_at        timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
-- P28: message_broadcasts · a few per week · the admin list reads one status, newest first
CREATE INDEX message_broadcasts_status_idx ON public.message_broadcasts (status, created_at DESC);

CREATE TABLE public.message_broadcast_batches (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  broadcast_id  bigint NOT NULL REFERENCES public.message_broadcasts (id) ON DELETE CASCADE,
  seq           integer NOT NULL CHECK (seq >= 1),
  status        text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'running', 'done', 'failed', 'cancelled')),
  size          integer NOT NULL CHECK (size >= 1),
  delivered     integer NOT NULL DEFAULT 0,
  failed        integer NOT NULL DEFAULT 0,
  attempts      integer NOT NULL DEFAULT 0,
  run_at        timestamptz NOT NULL DEFAULT now(),
  started_at    timestamptz,
  finished_at   timestamptz,
  last_error    text,
  CONSTRAINT message_broadcast_batches_seq UNIQUE (broadcast_id, seq)
);

CREATE TABLE public.message_broadcast_recipients (
  broadcast_id     bigint NOT NULL REFERENCES public.message_broadcasts (id) ON DELETE CASCADE,
  user_id          uuid NOT NULL,
  batch_id         bigint,
  status           text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'delivered', 'failed', 'withdrawn')),
  message_id       bigint,
  conversation_id  uuid,
  error            text,
  delivered_at     timestamptz,
  PRIMARY KEY (broadcast_id, user_id)
);
-- P28: message_broadcast_recipients · one row per member per broadcast (thousands) · a batch job reads its own waiting rows
CREATE INDEX message_broadcast_recipients_batch_idx ON public.message_broadcast_recipients (batch_id, status);
-- P28: message_broadcast_recipients · thousands per broadcast · the report filters one broadcast by status
CREATE INDEX message_broadcast_recipients_status_idx ON public.message_broadcast_recipients (broadcast_id, status);

ALTER TABLE public.message_broadcasts           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_broadcast_batches    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_broadcast_recipients ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_broadcasts, public.message_broadcast_batches, public.message_broadcast_recipients FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_broadcasts, public.message_broadcast_batches, public.message_broadcast_recipients TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- ── 3. job kinds ───────────────────────────────────────────────────────────
INSERT INTO public.job_kinds (kind, handler, max_attempts, backoff_seconds, timeout_seconds, max_running, note) VALUES
  ('message.broadcast_batch', 'sql:public.message_broadcast_run_batch', 3, ARRAY[60, 300], 150, 1,
   'M12: one batch (500 members) of a message broadcast; batches run one at a time, a minute apart'),
  ('message.broadcast_withdraw', 'sql:public.message_broadcast_withdraw_run', 3, ARRAY[60, 300], 150, 1,
   'M12: removes a withdrawn broadcast from the message boxes, 500 at a time');

-- ── 4. the push for a stored message: brand name for an admin sender; a broadcast can switch it off ──
CREATE OR REPLACE FUNCTION public.messages_push()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _r      record;
  _name   text;
  _push   boolean;
BEGIN
  IF NEW.status <> 'sent' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status <> 'held' THEN RETURN NEW; END IF;
  IF coalesce(current_setting('messages.skip_push', true), '') = 'on' THEN RETURN NEW; END IF;   -- a broadcast saved with push off
  IF NOT (coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false)
          AND coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine_push'), false)) THEN
    RETURN NEW;
  END IF;
  BEGIN
    IF public.has_role(NEW.sender_id, 'admin'::public.app_role) THEN
      _name := '50mm Retina World';                                       -- an admin always shows as the brand
    ELSE
      SELECT coalesce(nullif(btrim(p.full_name), ''), 'Someone') INTO _name FROM public.profiles p WHERE p.id = NEW.sender_id;
      _name := coalesce(_name, 'Someone');
    END IF;
    FOR _r IN
      SELECT m.user_id, m.folder
        FROM public.conversation_members m
       WHERE m.conversation_id = NEW.conversation_id
         AND m.user_id <> NEW.sender_id
         AND NOT m.muted
         AND m.folder <> 'declined'
    LOOP
      SELECT coalesce((SELECT np.push_enabled FROM public.notification_preferences np WHERE np.user_id = _r.user_id), true) INTO _push;
      IF NOT _push THEN CONTINUE; END IF;
      PERFORM public.job_start(public.job_enqueue(
        'push.send',
        jsonb_build_object(
          'user_id', _r.user_id,
          'title', _name,
          'body', CASE WHEN _r.folder = 'requests' THEN 'sent you a message request' ELSE 'sent you a message' END,
          'data', jsonb_build_object('type', 'new_message', 'reference_id', NEW.conversation_id::text)),
        'message:' || NEW.id::text || ':' || _r.user_id::text));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'messages_push: could not queue the push for message % (%)', NEW.id, SQLSTATE;
  END;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.messages_push() FROM PUBLIC, anon, authenticated;

-- ── 5. admin: save a draft ─────────────────────────────────────────────────
CREATE FUNCTION public.message_broadcast_admin()
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGBC-001: only an admin can use broadcasts' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN _uid;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_broadcast_admin() FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.admin_message_broadcast_save(_id bigint, _fields jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := public.message_broadcast_admin();
  _title text := btrim(coalesce(_fields ->> 'title', ''));
  _body text := btrim(coalesce(_fields ->> 'body', ''));
  _photos jsonb := coalesce(_fields -> 'photos', '[]'::jsonb);
  _aud jsonb := public.push_audience_check(coalesce(_fields -> 'audience', '{"kind":"all"}'::jsonb));
  _push boolean := coalesce((_fields ->> 'push')::boolean, true);
  _p jsonb; _out bigint; _o record; _norm jsonb := '[]'::jsonb;
BEGIN
  IF _title = '' OR char_length(_title) > 120 THEN
    RAISE EXCEPTION 'MSGBC-002: a title of 1–120 characters is required (only you see it)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF char_length(_body) > 4000 THEN
    RAISE EXCEPTION 'MSGBC-002: the message is longer than 4000 characters' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF jsonb_typeof(_photos) <> 'array' OR jsonb_array_length(_photos) > 10 THEN
    RAISE EXCEPTION 'MSGBC-002: at most 10 pictures' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  -- every picture must be YOUR upload in the messages bucket; type and size come from storage, not from the browser
  FOR _p IN SELECT e FROM jsonb_array_elements(_photos) e LOOP
    IF jsonb_typeof(_p) <> 'object' OR coalesce(_p ->> 'path', '') = '' OR (storage.foldername(_p ->> 'path'))[1] IS DISTINCT FROM _uid::text THEN
      RAISE EXCEPTION 'MSGBC-002: a picture is missing or not yours' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT o.metadata ->> 'mimetype' AS mime, (o.metadata ->> 'size')::bigint AS bytes INTO _o
      FROM storage.objects o WHERE o.bucket_id = 'message-photos' AND o.name = _p ->> 'path';
    IF NOT FOUND OR _o.mime NOT IN ('image/jpeg', 'image/png', 'image/webp') OR _o.bytes IS NULL OR _o.bytes < 1 OR _o.bytes > 5000000 THEN
      RAISE EXCEPTION 'MSGBC-002: a picture is missing, the wrong type or too big' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    _norm := _norm || jsonb_build_array(jsonb_build_object('path', _p ->> 'path', 'mime', _o.mime, 'bytes', _o.bytes,
                                                           'width', nullif(_p ->> 'width', '')::int, 'height', nullif(_p ->> 'height', '')::int));
  END LOOP;
  _photos := _norm;

  IF _id IS NULL THEN
    INSERT INTO public.message_broadcasts (title, body, photos, audience, push, sender_id, created_by)
    VALUES (_title, _body, _photos, _aud, _push, _uid, _uid) RETURNING id INTO _out;
  ELSE
    UPDATE public.message_broadcasts SET title = _title, body = _body, photos = _photos, audience = _aud, push = _push, updated_at = now()
     WHERE id = _id AND status = 'draft' RETURNING id INTO _out;
    IF _out IS NULL THEN
      RAISE EXCEPTION 'MSGBC-005: only a draft can be changed' USING ERRCODE = 'invalid_parameter_value';
    END IF;
  END IF;
  RETURN _out;
END
$fn$;

-- the honest count: who would really get it
CREATE FUNCTION public.admin_message_broadcast_audience(_audience jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_broadcast_admin(); _aud jsonb := public.push_audience_check(_audience); _matched int; _recv int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE a.eligible AND a.member_id <> _uid AND public.account_can_act(a.member_id))
    INTO _matched, _recv FROM public.push_audience_members(_aud) a;
  RETURN jsonb_build_object('matched', _matched, 'will_receive', _recv, 'left_out', _matched - _recv);
END
$fn$;

-- ── 6. admin: send now / at a time ─────────────────────────────────────────
CREATE FUNCTION public.admin_message_broadcast_send(_id bigint, _at timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := public.message_broadcast_admin();
  c public.message_broadcasts;
  b record;
  _n integer; _k integer; _start timestamptz;
BEGIN
  SELECT * INTO c FROM public.message_broadcasts WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MSGBC-004: no such broadcast' USING ERRCODE = 'no_data_found'; END IF;
  IF c.status <> 'draft' THEN RAISE EXCEPTION 'MSGBC-005: this broadcast was already sent or cancelled' USING ERRCODE = 'invalid_parameter_value'; END IF;
  IF c.body = '' AND jsonb_array_length(c.photos) = 0 THEN
    RAISE EXCEPTION 'MSGBC-002: write a message or add a picture first' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _at IS NOT NULL AND _at < now() - interval '1 minute' THEN
    RAISE EXCEPTION 'MSGBC-002: that time is in the past' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  _start := greatest(coalesce(_at, now()), now());

  INSERT INTO public.message_broadcast_recipients (broadcast_id, user_id)
  SELECT _id, a.member_id FROM public.push_audience_members(c.audience) a
   WHERE a.eligible AND a.member_id <> c.sender_id AND public.account_can_act(a.member_id);
  GET DIAGNOSTICS _n = ROW_COUNT;
  IF _n = 0 THEN RAISE EXCEPTION 'MSGBC-003: nobody in this audience can receive messages' USING ERRCODE = 'invalid_parameter_value'; END IF;
  IF _n > 200000 THEN RAISE EXCEPTION 'MSGBC-003: audience too large for one broadcast (200000)' USING ERRCODE = 'invalid_parameter_value'; END IF;
  _k := ceil(_n::numeric / c.batch_size)::int;

  INSERT INTO public.message_broadcast_batches (broadcast_id, seq, size, run_at)
  SELECT _id, g, least(c.batch_size, _n - (g - 1) * c.batch_size), _start + make_interval(secs => (g - 1) * c.batch_gap_seconds)
    FROM generate_series(1, _k) g;

  UPDATE public.message_broadcast_recipients r SET batch_id = bt.id
    FROM (SELECT x.user_id, ((x.rn - 1) / c.batch_size + 1)::int AS seq
            FROM (SELECT rr.user_id, row_number() OVER (ORDER BY rr.user_id) AS rn FROM public.message_broadcast_recipients rr WHERE rr.broadcast_id = _id) x) y
    JOIN public.message_broadcast_batches bt ON bt.broadcast_id = _id AND bt.seq = y.seq
   WHERE r.broadcast_id = _id AND r.user_id = y.user_id;

  UPDATE public.message_broadcasts
     SET status = CASE WHEN _start > now() + interval '30 seconds' THEN 'scheduled' ELSE 'sending' END,
         send_at = _at, total_members = _n, started_at = _start, updated_at = now()
   WHERE id = _id;

  FOR b IN SELECT id, seq, run_at FROM public.message_broadcast_batches WHERE broadcast_id = _id ORDER BY seq LOOP
    PERFORM public.job_enqueue('message.broadcast_batch', jsonb_build_object('batch_id', b.id), 'bcast:' || b.id::text || ':1', b.run_at);
  END LOOP;
  RETURN jsonb_build_object('broadcast_id', _id, 'recipients', _n, 'batches', _k, 'first_run_at', _start,
    'engine_on', coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false));
END
$fn$;

-- ── 7. the batch job ───────────────────────────────────────────────────────
CREATE FUNCTION public.message_broadcast_roll_up(_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.message_broadcast_batches WHERE broadcast_id = _id AND status IN ('waiting', 'running'))
     AND EXISTS (SELECT 1 FROM public.message_broadcasts WHERE id = _id AND status IN ('sending', 'scheduled')) THEN
    UPDATE public.message_broadcasts SET status = 'done', finished_at = now(), updated_at = now() WHERE id = _id;
  END IF;
END
$fn$;

CREATE FUNCTION public.message_broadcast_run_batch(_p jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _bid bigint := (_p ->> 'batch_id')::bigint;
  b public.message_broadcast_batches;
  c public.message_broadcasts;
  r record;
  _key uuid; _dkey text; _conv uuid; _msg bigint; _folder text; _kind text;
BEGIN
  SELECT * INTO b FROM public.message_broadcast_batches WHERE id = _bid FOR UPDATE;
  IF NOT FOUND OR b.status = 'done' THEN RETURN; END IF;
  SELECT * INTO c FROM public.message_broadcasts WHERE id = b.broadcast_id;
  IF c.status IN ('cancelled', 'withdrawn') THEN
    UPDATE public.message_broadcast_batches SET status = 'cancelled', finished_at = now() WHERE id = _bid;
    RETURN;
  END IF;
  IF c.status IN ('paused', 'draft') THEN
    UPDATE public.message_broadcast_batches SET status = 'waiting' WHERE id = _bid;     -- picked up again by "resume"
    RETURN;
  END IF;
  IF c.status = 'scheduled' THEN UPDATE public.message_broadcasts SET status = 'sending', updated_at = now() WHERE id = c.id; END IF;
  UPDATE public.message_broadcast_batches SET status = 'running', started_at = coalesce(started_at, now()), attempts = attempts + 1 WHERE id = _bid;
  PERFORM set_config('messages.skip_push', CASE WHEN c.push THEN 'off' ELSE 'on' END, true);
  _kind := CASE WHEN jsonb_array_length(c.photos) > 0 THEN 'photo' ELSE 'text' END;

  FOR r IN SELECT user_id FROM public.message_broadcast_recipients WHERE batch_id = _bid AND status = 'waiting' ORDER BY user_id LOOP
    BEGIN
      IF EXISTS (SELECT 1 FROM public.user_blocks ub
                  WHERE (ub.blocker_id = c.sender_id AND ub.blocked_id = r.user_id) OR (ub.blocker_id = r.user_id AND ub.blocked_id = c.sender_id)) THEN
        RAISE EXCEPTION 'blocked';
      END IF;
      _dkey := least(c.sender_id::text, r.user_id::text) || ':' || greatest(c.sender_id::text, r.user_id::text);
      _conv := NULL;
      INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', _dkey, c.sender_id)
        ON CONFLICT (direct_key) DO NOTHING RETURNING id INTO _conv;
      IF _conv IS NULL THEN SELECT cv.id INTO _conv FROM public.conversations cv WHERE cv.direct_key = _dkey; END IF;
      INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conv, c.sender_id, 'owner', 'inbox') ON CONFLICT DO NOTHING;
      INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conv, r.user_id, 'member', 'inbox') ON CONFLICT DO NOTHING;
      SELECT cm.folder INTO _folder FROM public.conversation_members cm WHERE cm.conversation_id = _conv AND cm.user_id = r.user_id;
      IF _folder = 'declined' THEN RAISE EXCEPTION 'declined this chat'; END IF;

      _key := md5('broadcast:' || c.id::text || ':' || r.user_id::text)::uuid;
      _msg := NULL;
      INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id)
      VALUES (_conv, c.sender_id, _kind, c.body, _key)
      ON CONFLICT (sender_id, client_msg_id) DO NOTHING RETURNING id INTO _msg;
      IF _msg IS NULL THEN
        SELECT m.id INTO _msg FROM public.messages m WHERE m.sender_id = c.sender_id AND m.client_msg_id = _key;     -- stored by an earlier try
      ELSE
        INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes, width, height)
        SELECT _msg, e ->> 'path', e ->> 'mime', coalesce((e ->> 'bytes')::int, 1), nullif(e ->> 'width', '')::int, nullif(e ->> 'height', '')::int
          FROM jsonb_array_elements(c.photos) e;
        UPDATE public.conversations SET last_message_at = now() WHERE id = _conv;
      END IF;
      UPDATE public.message_broadcast_recipients
         SET status = 'delivered', message_id = _msg, conversation_id = _conv, delivered_at = now(), error = NULL
       WHERE broadcast_id = c.id AND user_id = r.user_id;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.message_broadcast_recipients SET status = 'failed', error = left(SQLERRM, 200)
       WHERE broadcast_id = c.id AND user_id = r.user_id;
    END;
  END LOOP;

  UPDATE public.message_broadcast_batches x
     SET delivered = (SELECT count(*) FROM public.message_broadcast_recipients q WHERE q.batch_id = _bid AND q.status = 'delivered'),
         failed    = (SELECT count(*) FROM public.message_broadcast_recipients q WHERE q.batch_id = _bid AND q.status = 'failed'),
         status    = CASE WHEN NOT EXISTS (SELECT 1 FROM public.message_broadcast_recipients q WHERE q.batch_id = _bid AND q.status <> 'failed') THEN 'failed' ELSE 'done' END,
         finished_at = now(),
         last_error = (SELECT q.error FROM public.message_broadcast_recipients q WHERE q.batch_id = _bid AND q.status = 'failed' ORDER BY q.user_id LIMIT 1)
   WHERE x.id = _bid;
  PERFORM public.message_broadcast_roll_up(c.id);
END
$fn$;

-- ── 8. admin: pause / resume / cancel / retry the failed ───────────────────
CREATE FUNCTION public.admin_message_broadcast_control(_id bigint, _action text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := public.message_broadcast_admin();
  c public.message_broadcasts;
  b record; _i int := 0; _stamp text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');
BEGIN
  IF _action NOT IN ('pause', 'resume', 'cancel', 'retry_failed') THEN
    RAISE EXCEPTION 'MSGBC-006: action must be pause, resume, cancel or retry_failed' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO c FROM public.message_broadcasts WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MSGBC-004: no such broadcast' USING ERRCODE = 'no_data_found'; END IF;

  IF _action = 'pause' THEN
    IF c.status NOT IN ('sending', 'scheduled') THEN RAISE EXCEPTION 'MSGBC-005: nothing to pause' USING ERRCODE = 'invalid_parameter_value'; END IF;
    UPDATE public.message_broadcasts SET status = 'paused', updated_at = now() WHERE id = _id;
  ELSIF _action = 'cancel' THEN
    IF c.status NOT IN ('draft', 'scheduled', 'sending', 'paused') THEN RAISE EXCEPTION 'MSGBC-005: this broadcast cannot be cancelled' USING ERRCODE = 'invalid_parameter_value'; END IF;
    UPDATE public.message_broadcast_batches SET status = 'cancelled', finished_at = now() WHERE broadcast_id = _id AND status IN ('waiting');
    UPDATE public.message_broadcast_recipients SET status = 'failed', error = 'cancelled' WHERE broadcast_id = _id AND status = 'waiting';
    UPDATE public.message_broadcasts SET status = 'cancelled', finished_at = now(), updated_at = now() WHERE id = _id;
  ELSIF _action = 'resume' THEN
    IF c.status <> 'paused' THEN RAISE EXCEPTION 'MSGBC-005: this broadcast is not paused' USING ERRCODE = 'invalid_parameter_value'; END IF;
    UPDATE public.message_broadcasts SET status = 'sending', updated_at = now() WHERE id = _id;
    FOR b IN SELECT id FROM public.message_broadcast_batches WHERE broadcast_id = _id AND status = 'waiting' ORDER BY seq LOOP
      PERFORM public.job_enqueue('message.broadcast_batch', jsonb_build_object('batch_id', b.id), 'bcast:' || b.id::text || ':r' || _stamp,
                                 now() + make_interval(secs => _i * c.batch_gap_seconds));
      _i := _i + 1;
    END LOOP;
    PERFORM public.message_broadcast_roll_up(_id);
  ELSE  -- retry_failed
    IF c.status NOT IN ('done', 'sending', 'paused') THEN RAISE EXCEPTION 'MSGBC-005: nothing to retry yet' USING ERRCODE = 'invalid_parameter_value'; END IF;
    UPDATE public.message_broadcast_recipients SET status = 'waiting', error = NULL WHERE broadcast_id = _id AND status = 'failed' AND error IS DISTINCT FROM 'cancelled';
    IF NOT FOUND THEN RAISE EXCEPTION 'MSGBC-005: no failed members to retry' USING ERRCODE = 'invalid_parameter_value'; END IF;
    UPDATE public.message_broadcast_batches bt SET status = 'waiting', finished_at = NULL
     WHERE bt.broadcast_id = _id AND EXISTS (SELECT 1 FROM public.message_broadcast_recipients q WHERE q.batch_id = bt.id AND q.status = 'waiting');
    UPDATE public.message_broadcasts SET status = CASE WHEN status = 'paused' THEN 'paused' ELSE 'sending' END, finished_at = NULL, updated_at = now() WHERE id = _id;
    IF (SELECT status FROM public.message_broadcasts WHERE id = _id) = 'sending' THEN
      FOR b IN SELECT id FROM public.message_broadcast_batches WHERE broadcast_id = _id AND status = 'waiting' ORDER BY seq LOOP
        PERFORM public.job_enqueue('message.broadcast_batch', jsonb_build_object('batch_id', b.id), 'bcast:' || b.id::text || ':r' || _stamp,
                                   now() + make_interval(secs => _i * c.batch_gap_seconds));
        _i := _i + 1;
      END LOOP;
    END IF;
  END IF;
  RETURN (SELECT status FROM public.message_broadcasts WHERE id = _id);
END
$fn$;

-- ── 9. admin: withdraw (take it out of every message box) ──────────────────
CREATE FUNCTION public.admin_message_broadcast_withdraw(_id bigint)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_broadcast_admin(); c public.message_broadcasts;
BEGIN
  SELECT * INTO c FROM public.message_broadcasts WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MSGBC-004: no such broadcast' USING ERRCODE = 'no_data_found'; END IF;
  IF c.status NOT IN ('sending', 'paused', 'done', 'cancelled') THEN
    RAISE EXCEPTION 'MSGBC-005: this broadcast cannot be withdrawn' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  UPDATE public.message_broadcast_batches SET status = 'cancelled', finished_at = now() WHERE broadcast_id = _id AND status IN ('waiting');
  UPDATE public.message_broadcast_recipients SET status = 'failed', error = 'withdrawn' WHERE broadcast_id = _id AND status = 'waiting';
  UPDATE public.message_broadcasts SET status = 'withdrawn', finished_at = coalesce(finished_at, now()), updated_at = now() WHERE id = _id;
  PERFORM public.job_enqueue('message.broadcast_withdraw', jsonb_build_object('broadcast_id', _id), 'bcastw:' || _id::text || ':1');
  RETURN 'withdrawn';
END
$fn$;

CREATE FUNCTION public.message_broadcast_withdraw_run(_p jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _id bigint := (_p ->> 'broadcast_id')::bigint;
  _next integer := coalesce((_p ->> 'round')::int, 1) + 1;
  _msgs bigint[]; _convs uuid[];
BEGIN
  SELECT array_agg(x.message_id), array_agg(DISTINCT x.conversation_id) INTO _msgs, _convs FROM (
    SELECT r.message_id, r.conversation_id FROM public.message_broadcast_recipients r
     WHERE r.broadcast_id = _id AND r.status = 'delivered' AND r.message_id IS NOT NULL ORDER BY r.user_id LIMIT 500) x;
  IF _msgs IS NOT NULL THEN
    DELETE FROM public.messages WHERE id = ANY (_msgs);                                   -- the pictures go with them (cascade)
    UPDATE public.message_broadcast_recipients SET status = 'withdrawn' WHERE broadcast_id = _id AND message_id = ANY (_msgs);
    UPDATE public.conversations c SET last_message_at = (SELECT max(m.created_at) FROM public.messages m WHERE m.conversation_id = c.id AND m.status = 'sent')
     WHERE c.id = ANY (_convs);
  END IF;
  IF EXISTS (SELECT 1 FROM public.message_broadcast_recipients r WHERE r.broadcast_id = _id AND r.status = 'delivered' AND r.message_id IS NOT NULL) THEN
    PERFORM public.job_enqueue('message.broadcast_withdraw', jsonb_build_object('broadcast_id', _id, 'round', _next), 'bcastw:' || _id::text || ':' || _next::text);
  END IF;
END
$fn$;

-- ── 10. admin reads: list, report, per-member ──────────────────────────────
CREATE FUNCTION public.admin_message_broadcasts(_status text DEFAULT NULL, _limit integer DEFAULT 25, _offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_broadcast_admin(); _res jsonb;
BEGIN
  IF _status IS NOT NULL AND _status NOT IN ('draft', 'scheduled', 'sending', 'paused', 'done', 'cancelled', 'withdrawn') THEN
    RAISE EXCEPTION 'MSGBC-006: unknown status' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM public.message_broadcasts WHERE _status IS NULL OR status = _status),
    'counts', (SELECT coalesce(jsonb_object_agg(s.status, s.n), '{}'::jsonb) FROM (SELECT status, count(*) AS n FROM public.message_broadcasts GROUP BY status) s),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', p.id, 'title', p.title, 'body', left(p.body, 200), 'status', p.status, 'audience', p.audience, 'push', p.push,
        'photos', jsonb_array_length(p.photos), 'total_members', p.total_members, 'created_at', p.created_at, 'send_at', p.send_at,
        'started_at', p.started_at, 'finished_at', p.finished_at, 'sender_name', sp.full_name,
        'delivered', (SELECT count(*) FROM public.message_broadcast_recipients r WHERE r.broadcast_id = p.id AND r.status = 'delivered'),
        'failed',    (SELECT count(*) FROM public.message_broadcast_recipients r WHERE r.broadcast_id = p.id AND r.status = 'failed'),
        'read',      (SELECT count(*) FROM public.message_broadcast_recipients r
                        JOIN public.messages m ON m.id = r.message_id
                        JOIN public.conversation_members cm ON cm.conversation_id = r.conversation_id AND cm.user_id = r.user_id
                       WHERE r.broadcast_id = p.id AND r.status = 'delivered' AND cm.last_read_at >= m.created_at),
        'batches_total', (SELECT count(*) FROM public.message_broadcast_batches q WHERE q.broadcast_id = p.id),
        'batches_done',  (SELECT count(*) FROM public.message_broadcast_batches q WHERE q.broadcast_id = p.id AND q.status IN ('done', 'failed')))
        ORDER BY p.created_at DESC)
      FROM (SELECT * FROM public.message_broadcasts WHERE _status IS NULL OR status = _status
             ORDER BY created_at DESC LIMIT least(greatest(coalesce(_limit, 25), 1), 100) OFFSET greatest(coalesce(_offset, 0), 0)) p
      LEFT JOIN public.profiles sp ON sp.id = p.sender_id), '[]'::jsonb)) INTO _res;
  RETURN _res;
END
$fn$;

CREATE FUNCTION public.admin_message_broadcast_report(_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_broadcast_admin(); c public.message_broadcasts; _read int; _deliv int; _fail int; _wait int; _wd int;
BEGIN
  SELECT * INTO c FROM public.message_broadcasts WHERE id = _id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MSGBC-004: no such broadcast' USING ERRCODE = 'no_data_found'; END IF;
  SELECT count(*) FILTER (WHERE r.status = 'delivered'), count(*) FILTER (WHERE r.status = 'failed'),
         count(*) FILTER (WHERE r.status = 'waiting'), count(*) FILTER (WHERE r.status = 'withdrawn')
    INTO _deliv, _fail, _wait, _wd FROM public.message_broadcast_recipients r WHERE r.broadcast_id = _id;
  SELECT count(*) INTO _read FROM public.message_broadcast_recipients r
    JOIN public.messages m ON m.id = r.message_id
    JOIN public.conversation_members cm ON cm.conversation_id = r.conversation_id AND cm.user_id = r.user_id
   WHERE r.broadcast_id = _id AND r.status = 'delivered' AND cm.last_read_at >= m.created_at;
  RETURN jsonb_build_object(
    'broadcast', jsonb_build_object('id', c.id, 'title', c.title, 'body', c.body, 'photos', c.photos, 'audience', c.audience, 'push', c.push,
                                    'status', c.status, 'sender_id', c.sender_id, 'batch_size', c.batch_size, 'batch_gap_seconds', c.batch_gap_seconds,
                                    'send_at', c.send_at, 'total_members', c.total_members, 'created_at', c.created_at,
                                    'started_at', c.started_at, 'finished_at', c.finished_at),
    'totals', jsonb_build_object('audience', coalesce(c.total_members, 0), 'delivered', _deliv, 'failed', _fail, 'waiting', _wait,
                                 'withdrawn', _wd, 'read', _read, 'unread', greatest(_deliv - _read, 0)),
    'batches', coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'seq', b.seq, 'status', b.status, 'size', b.size, 'delivered', b.delivered,
                                    'failed', b.failed, 'attempts', b.attempts, 'run_at', b.run_at, 'started_at', b.started_at,
                                    'finished_at', b.finished_at, 'last_error', b.last_error) ORDER BY b.seq)
                           FROM public.message_broadcast_batches b WHERE b.broadcast_id = _id), '[]'::jsonb),
    'engine_on', coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false));
END
$fn$;

CREATE FUNCTION public.admin_message_broadcast_recipients(_id bigint, _filter text DEFAULT 'all', _q text DEFAULT NULL, _limit integer DEFAULT 25, _offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := public.message_broadcast_admin();
  _needle text := lower(btrim(coalesce(_q, '')));
  _res jsonb;
BEGIN
  IF _filter NOT IN ('all', 'delivered', 'failed', 'read', 'unread', 'waiting') THEN
    RAISE EXCEPTION 'MSGBC-006: filter must be all, delivered, failed, read, unread or waiting' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  WITH base AS (
    SELECT r.user_id, r.status, r.error, r.delivered_at, p.full_name, p.custom_url AS username, p.avatar_url,
           (r.status = 'delivered' AND coalesce(cm.last_read_at >= m.created_at, false)) AS is_read,
           CASE WHEN r.status = 'delivered' AND cm.last_read_at >= m.created_at THEN cm.last_read_at END AS read_at
      FROM public.message_broadcast_recipients r
      LEFT JOIN public.profiles p ON p.id = r.user_id
      LEFT JOIN public.messages m ON m.id = r.message_id
      LEFT JOIN public.conversation_members cm ON cm.conversation_id = r.conversation_id AND cm.user_id = r.user_id
     WHERE r.broadcast_id = _id
       AND (_needle = '' OR position(_needle in lower(coalesce(p.full_name, ''))) > 0 OR position(_needle in lower(coalesce(p.custom_url, ''))) > 0)),
  shown AS (
    SELECT * FROM base b WHERE CASE _filter WHEN 'delivered' THEN b.status = 'delivered' WHEN 'failed' THEN b.status = 'failed'
                                            WHEN 'read' THEN b.is_read WHEN 'unread' THEN b.status = 'delivered' AND NOT b.is_read
                                            WHEN 'waiting' THEN b.status = 'waiting' ELSE true END)
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM shown),
    'counts', jsonb_build_object('all', (SELECT count(*) FROM base), 'delivered', (SELECT count(*) FROM base WHERE status = 'delivered'),
                                 'failed', (SELECT count(*) FROM base WHERE status = 'failed'), 'read', (SELECT count(*) FROM base WHERE is_read),
                                 'unread', (SELECT count(*) FROM base WHERE status = 'delivered' AND NOT is_read),
                                 'waiting', (SELECT count(*) FROM base WHERE status = 'waiting')),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', s.user_id, 'full_name', s.full_name, 'username', s.username, 'avatar_url', s.avatar_url,
                                'status', s.status, 'error', s.error, 'delivered_at', s.delivered_at, 'read', s.is_read, 'read_at', s.read_at))
                        FROM (SELECT * FROM shown ORDER BY lower(coalesce(full_name, '')), user_id
                               LIMIT least(greatest(coalesce(_limit, 25), 1), 200) OFFSET greatest(coalesce(_offset, 0), 0)) s), '[]'::jsonb))
    INTO _res;
  RETURN _res;
END
$fn$;

-- ── 11. rights ─────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.message_broadcast_roll_up(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_broadcast_run_batch(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_broadcast_withdraw_run(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_broadcast_roll_up(bigint), public.message_broadcast_run_batch(jsonb), public.message_broadcast_withdraw_run(jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.admin_message_broadcast_save(bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_broadcast_audience(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_broadcast_send(bigint, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_broadcast_control(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_broadcast_withdraw(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_broadcasts(text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_broadcast_report(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_broadcast_recipients(bigint, text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_message_broadcast_save(bigint, jsonb), public.admin_message_broadcast_audience(jsonb),
  public.admin_message_broadcast_send(bigint, timestamptz), public.admin_message_broadcast_control(bigint, text),
  public.admin_message_broadcast_withdraw(bigint), public.admin_message_broadcasts(text, integer, integer),
  public.admin_message_broadcast_report(bigint), public.admin_message_broadcast_recipients(bigint, text, text, integer, integer)
  TO authenticated, service_role;

COMMIT;

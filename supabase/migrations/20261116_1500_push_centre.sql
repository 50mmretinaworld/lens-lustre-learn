-- ═══════════════════════════════════════════════════════════════════════════
-- 20261116_1500 · PUSH CENTRE PN1 — one record per admin push, audiences,
-- schedule, history, drafts / templates. Owner approved items 1–10, 16 Nov 2026
-- ("/admin/push_notification very old … app users 80 but goes to 45").
--
-- Measured first (production PROBE_20261102_0100, run 43861928230, 16 Nov):
-- 80 members were last seen in the app, but push_tokens holds 54 Android
-- devices of 53 members. The page showed one number with no reason, kept no
-- record of a send, and sent to everyone or no one.
--
-- WHAT IT ADDS (expand only — nothing existing changes behaviour)
--   push_tokens.app_version / caps   what an app build can show ('rich' =
--            countdown, buttons, carousel). Old builds leave them empty and
--            keep getting today's plain notification.
--   push_permission_state            the app's last "Allow notifications?"
--            answer per member (new builds report it), so the audience can say
--            "said No" instead of guessing.
--   push_broadcasts                  one row per admin message, draft or
--            template: content, audience, schedule, who, and the outcome
--            (members / devices targeted, delivered, failed, removed, opened,
--            failure reasons).
--   notification_deliveries.broadcast_id   each member's receipt (N4) points
--            at its broadcast; the existing "opened" receipt counts opens.
--   job kind push.broadcast          a scheduled send runs on the one job
--            engine (J1) → edge send-broadcast-push. Never twice: the send
--            claims the row (scheduled → sending) once.
--   admin RPCs  admin_push_audience · admin_push_broadcast_save ·
--            admin_push_broadcast_schedule · admin_push_broadcast_cancel ·
--            admin_push_broadcast_delete · admin_push_broadcasts
--   member RPCs register_push_device · report_push_permission (new builds)
--   service RPCs push_broadcast_claim · push_broadcast_finish (edge only)
--
-- Who receives: members in the chosen audience whose status is active or
-- under review. Banned, suspended and asked-to-delete members are held back
-- and counted as such.
--
-- Rollback: supabase/rollback/20261116_1500_push_centre_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261116_1500_push_centre.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regclass('public.push_tokens') IS NULL OR to_regclass('public.notification_deliveries') IS NULL
     OR to_regclass('public.account_states') IS NULL OR to_regclass('public.user_roles') IS NULL
     OR to_regclass('public.user_badges') IS NULL THEN
    RAISE EXCEPTION 'PC-1500-PRE-001: push_tokens / notification_deliveries / account_states / user_roles / user_badges missing';
  END IF;
  IF to_regprocedure('public.job_enqueue(text,jsonb,text,timestamp with time zone)') IS NULL
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                     AND table_name = 'job_kinds' AND column_name = 'extra_headers_secret') THEN
    RAISE EXCEPTION 'PC-1500-PRE-002: job engine with per-kind headers (20261115_1100 + 1200) is not on this lane';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE extra_headers_secret = 'jobs:edge:send-push') THEN
    RAISE EXCEPTION 'PC-1500-PRE-003: vault header jobs:edge:send-push (J3a) is not registered on this lane';
  END IF;
  IF to_regprocedure('public.member_status_of(boolean, boolean, text)') IS NULL THEN
    RAISE EXCEPTION 'PC-1500-PRE-004: member_status_of (20261116_1400) is not on this lane';
  END IF;
  IF to_regclass('public.push_broadcasts') IS NOT NULL OR to_regclass('public.push_permission_state') IS NOT NULL THEN
    RAISE EXCEPTION 'PC-1500-PRE-005: 1500 already applied — roll back first';
  END IF;
END
$pre$;

-- ── 1. what a device's app build can show ─────────────────────────────────
ALTER TABLE public.push_tokens
  ADD COLUMN app_version text CHECK (app_version ~ '^[0-9A-Za-z._-]{1,32}$'),
  ADD COLUMN caps text[] NOT NULL DEFAULT '{}'::text[] CHECK (cardinality(caps) <= 8);

-- ── 2. the app's last permission answer, per member ───────────────────────
CREATE TABLE public.push_permission_state (
  user_id     uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  permission  text NOT NULL CHECK (permission IN ('granted', 'denied', 'prompt')),
  platform    text NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
  app_version text CHECK (app_version ~ '^[0-9A-Za-z._-]{1,32}$'),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.push_permission_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_permission_state FROM PUBLIC, anon, authenticated;
-- no policies: written and read only through the definer functions below.

-- ── 3. one row per admin message ──────────────────────────────────────────
CREATE TABLE public.push_broadcasts (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind             text NOT NULL DEFAULT 'message' CHECK (kind IN ('message', 'template')),
  status           text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft', 'scheduled', 'sending', 'sent', 'failed', 'cancelled')),
  name             text CHECK (length(name) <= 80),
  title            text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 80),
  body             text NOT NULL DEFAULT '' CHECK (length(body) <= 240),
  image_url        text CHECK (image_url ~ '^https://' AND length(image_url) <= 600),
  images           text[] NOT NULL DEFAULT '{}'::text[] CHECK (cardinality(images) <= 5),
  link             text CHECK (link ~ '^/([A-Za-z0-9_-][A-Za-z0-9/_.?=&%#-]*)?$' AND length(link) <= 300),
  countdown_until  timestamptz,
  actions          jsonb NOT NULL DEFAULT '[]'::jsonb
                   CHECK (jsonb_typeof(actions) = 'array' AND jsonb_array_length(actions) <= 2),
  audience         jsonb NOT NULL DEFAULT '{"kind": "all"}'::jsonb,
  scheduled_at     timestamptz,
  job_id           bigint,
  created_by       uuid NOT NULL,
  updated_by       uuid,
  sent_by          uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  audience_members integer CHECK (audience_members >= 0),
  reached_members  integer CHECK (reached_members >= 0),
  devices          integer CHECK (devices >= 0),
  delivered        integer NOT NULL DEFAULT 0 CHECK (delivered >= 0),
  failed           integer NOT NULL DEFAULT 0 CHECK (failed >= 0),
  removed          integer NOT NULL DEFAULT 0 CHECK (removed >= 0),
  opened           integer NOT NULL DEFAULT 0 CHECK (opened >= 0),
  fail_reasons     jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(fail_reasons) = 'object'),
  CHECK (kind = 'message' OR status = 'draft')
);
-- P28: push_broadcasts · 0 rows at launch, a few per week · the admin lists (history / scheduled / drafts / templates) filter kind + status, newest first
CREATE INDEX push_broadcasts_list_idx ON public.push_broadcasts (kind, status, created_at DESC);
ALTER TABLE public.push_broadcasts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_broadcasts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_broadcasts TO service_role;

ALTER TABLE public.notification_deliveries
  ADD COLUMN broadcast_id bigint REFERENCES public.push_broadcasts (id) ON DELETE SET NULL;
-- P28: notification_deliveries · partial, broadcast rows only (30-day table) · push_broadcast_targets paging, push_broadcast_finish and the FK ON DELETE SET NULL scan
CREATE INDEX notification_deliveries_broadcast_idx ON public.notification_deliveries (broadcast_id)
  WHERE broadcast_id IS NOT NULL;

-- an "opened" receipt on a broadcast row adds one to the broadcast's count
CREATE FUNCTION public.push_broadcast_count_open()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.push_broadcasts SET opened = opened + 1 WHERE id = NEW.broadcast_id;
  RETURN NULL;
END
$fn$;
REVOKE ALL ON FUNCTION public.push_broadcast_count_open() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_push_broadcast_count_open
  AFTER UPDATE OF opened_at ON public.notification_deliveries
  FOR EACH ROW
  WHEN (NEW.broadcast_id IS NOT NULL AND OLD.opened_at IS NULL AND NEW.opened_at IS NOT NULL)
  EXECUTE FUNCTION public.push_broadcast_count_open();

-- ── 4. the scheduled-send job kind (one engine) ───────────────────────────
INSERT INTO public.job_kinds (kind, handler, max_attempts, backoff_seconds, timeout_seconds, max_running,
                              extra_headers_secret, note)
VALUES ('push.broadcast', 'edge:send-broadcast-push', 3, ARRAY[60, 300], 300, 2, 'jobs:edge:send-push',
        'PN1 1500: one admin push at its scheduled time (key broadcast:<id>); the send claims the row once');

-- ── 5. audience: validate, then resolve ───────────────────────────────────
-- {"kind":"all"} · {"kind":"active","days":7|30} · {"kind":"role","role":"…"}
-- {"kind":"badge","badge":"…"} · {"kind":"members","ids":[uuid, … ≤ 500]}
CREATE FUNCTION public.push_audience_check(_aud jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
DECLARE
  k text := _aud->>'kind';
BEGIN
  IF _aud IS NULL OR jsonb_typeof(_aud) <> 'object' THEN
    RAISE EXCEPTION 'audience must be an object' USING ERRCODE = '22023';
  END IF;
  IF k = 'all' THEN
    RETURN jsonb_build_object('kind', 'all');
  ELSIF k = 'active' AND (_aud->>'days') IN ('7', '30') THEN
    RETURN jsonb_build_object('kind', 'active', 'days', (_aud->>'days')::int);
  ELSIF k = 'role' AND (_aud->>'role') ~ '^[a-z_]{1,40}$' THEN
    RETURN jsonb_build_object('kind', 'role', 'role', _aud->>'role');
  ELSIF k = 'badge' AND (_aud->>'badge') ~ '^[a-z0-9_]{1,40}$' THEN
    RETURN jsonb_build_object('kind', 'badge', 'badge', _aud->>'badge');
  ELSIF k = 'members' AND jsonb_typeof(_aud->'ids') = 'array'
        AND jsonb_array_length(_aud->'ids') BETWEEN 1 AND 500 THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(_aud->'ids') e
                WHERE jsonb_typeof(e) <> 'string'
                   OR NOT (e #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'audience ids must be member ids' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object('kind', 'members',
      'ids', (SELECT jsonb_agg(DISTINCT lower(e #>> '{}')) FROM jsonb_array_elements(_aud->'ids') e));
  END IF;
  RAISE EXCEPTION 'unknown audience %', left(_aud::text, 120) USING ERRCODE = '22023';
END
$fn$;
REVOKE ALL ON FUNCTION public.push_audience_check(jsonb) FROM PUBLIC, anon, authenticated;

-- every member the audience names, whether they may receive, and why not
CREATE FUNCTION public.push_audience_members(_aud jsonb)
RETURNS TABLE (member_id uuid, eligible boolean, last_platform text, last_active_at timestamptz)
LANGUAGE sql STABLE SET search_path = ''
AS $fn$
  SELECT p.id,
         public.member_status_of(coalesce(p.is_banned, false), coalesce(p.is_suspended, false), s.state::text)
           IN ('active', 'under_review'),
         p.last_platform::text,
         p.last_active_at
    FROM public.profiles p
    LEFT JOIN public.account_states s ON s.user_id = p.id
   WHERE CASE _aud->>'kind'
           WHEN 'all'     THEN true
           WHEN 'active'  THEN p.last_active_at >= now() - make_interval(days => (_aud->>'days')::int)
           WHEN 'role'    THEN EXISTS (SELECT 1 FROM public.user_roles ur
                                        WHERE ur.user_id = p.id AND ur.role::text = _aud->>'role')
           WHEN 'badge'   THEN EXISTS (SELECT 1 FROM public.user_badges ub
                                        WHERE ub.user_id = p.id AND ub.badge_type::text = _aud->>'badge')
           WHEN 'members' THEN p.id::text IN (SELECT jsonb_array_elements_text(_aud->'ids'))
           ELSE false
         END
$fn$;
REVOKE ALL ON FUNCTION public.push_audience_members(jsonb) FROM PUBLIC, anon, authenticated;

-- ── 6. admin: the honest audience count ───────────────────────────────────
CREATE FUNCTION public.admin_push_audience(_audience jsonb)
RETURNS TABLE (
  matched bigint, held bigint, eligible bigint, reachable_members bigint, devices bigint, rich_devices bigint,
  said_no bigint, app_recent_no_phone bigint, app_old_no_phone bigint, website_only bigint,
  scheduling_on boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _aud jsonb;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  _aud := public.push_audience_check(_audience);
  RETURN QUERY
  WITH m AS (
    SELECT a.*,
           EXISTS (SELECT 1 FROM public.push_tokens t WHERE t.user_id = a.member_id) AS has_device,
           (SELECT ps.permission FROM public.push_permission_state ps WHERE ps.user_id = a.member_id) AS perm
      FROM public.push_audience_members(_aud) a
  )
  SELECT count(*),
         count(*) FILTER (WHERE NOT m.eligible),
         count(*) FILTER (WHERE m.eligible),
         count(*) FILTER (WHERE m.eligible AND m.has_device),
         (SELECT count(*) FROM public.push_tokens t JOIN m m2 ON m2.member_id = t.user_id AND m2.eligible),
         (SELECT count(*) FROM public.push_tokens t JOIN m m2 ON m2.member_id = t.user_id AND m2.eligible
           WHERE 'rich' = ANY (t.caps)),
         count(*) FILTER (WHERE m.eligible AND NOT m.has_device AND m.perm = 'denied'),
         count(*) FILTER (WHERE m.eligible AND NOT m.has_device AND m.perm IS DISTINCT FROM 'denied'
                            AND m.last_platform = 'app' AND m.last_active_at >= now() - interval '30 days'),
         count(*) FILTER (WHERE m.eligible AND NOT m.has_device AND m.perm IS DISTINCT FROM 'denied'
                            AND m.last_platform = 'app'
                            AND (m.last_active_at IS NULL OR m.last_active_at < now() - interval '30 days')),
         count(*) FILTER (WHERE m.eligible AND NOT m.has_device AND m.perm IS DISTINCT FROM 'denied'
                            AND m.last_platform IS DISTINCT FROM 'app'),
         coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false)
    FROM m;
END
$fn$;

-- ── 7. admin: save a draft or template (insert when _id is NULL) ──────────
CREATE FUNCTION public.admin_push_broadcast_save(_id bigint, _fields jsonb)
RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me      uuid := auth.uid();
  _kind    text := coalesce(_fields->>'kind', 'message');
  _images  text[];
  _actions jsonb := coalesce(_fields->'actions', '[]'::jsonb);
  _out     bigint;
BEGIN
  IF NOT public.has_role(_me, 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _fields IS NULL OR jsonb_typeof(_fields) <> 'object' THEN
    RAISE EXCEPTION 'fields must be an object' USING ERRCODE = '22023';
  END IF;
  IF _kind NOT IN ('message', 'template') THEN
    RAISE EXCEPTION 'kind must be message or template' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(coalesce(_fields->'images', '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'images must be a list' USING ERRCODE = '22023';
  END IF;
  SELECT coalesce(array_agg(x), '{}'::text[]) INTO _images
    FROM jsonb_array_elements_text(coalesce(_fields->'images', '[]'::jsonb)) x;
  IF EXISTS (SELECT 1 FROM unnest(_images) u WHERE u !~ '^https://' OR length(u) > 600) THEN
    RAISE EXCEPTION 'every picture must be an https address' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(_actions) <> 'array' THEN
    RAISE EXCEPTION 'buttons must be a list' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
       SELECT 1 FROM jsonb_array_elements(_actions) a
        WHERE jsonb_typeof(a) <> 'object'
           OR length(btrim(coalesce(a->>'label', ''))) NOT BETWEEN 1 AND 20
           OR coalesce(a->>'link', '') !~ '^/([A-Za-z0-9_-][A-Za-z0-9/_.?=&%#-]*)?$'
           OR length(a->>'link') > 300) THEN
    RAISE EXCEPTION 'each button needs a label (1–20 letters) and a link starting with /' USING ERRCODE = '22023';
  END IF;

  IF _id IS NULL THEN
    INSERT INTO public.push_broadcasts (kind, name, title, body, image_url, images, link, countdown_until,
                                        actions, audience, created_by, updated_by)
    VALUES (_kind, nullif(btrim(_fields->>'name'), ''), btrim(coalesce(_fields->>'title', '')),
            coalesce(_fields->>'body', ''), nullif(btrim(_fields->>'image_url'), ''), _images,
            nullif(btrim(_fields->>'link'), ''), (nullif(_fields->>'countdown_until', ''))::timestamptz,
            (SELECT coalesce(jsonb_agg(jsonb_build_object('label', btrim(a->>'label'), 'link', a->>'link')), '[]'::jsonb)
               FROM jsonb_array_elements(_actions) a),
            public.push_audience_check(coalesce(_fields->'audience', '{"kind":"all"}'::jsonb)), _me, _me)
    RETURNING id INTO _out;
  ELSE
    UPDATE public.push_broadcasts b
       SET name = nullif(btrim(_fields->>'name'), ''),
           title = btrim(coalesce(_fields->>'title', '')),
           body = coalesce(_fields->>'body', ''),
           image_url = nullif(btrim(_fields->>'image_url'), ''),
           images = _images,
           link = nullif(btrim(_fields->>'link'), ''),
           countdown_until = (nullif(_fields->>'countdown_until', ''))::timestamptz,
           actions = (SELECT coalesce(jsonb_agg(jsonb_build_object('label', btrim(a->>'label'), 'link', a->>'link')), '[]'::jsonb)
                        FROM jsonb_array_elements(_actions) a),
           audience = public.push_audience_check(coalesce(_fields->'audience', '{"kind":"all"}'::jsonb)),
           updated_by = _me,
           updated_at = now()
     WHERE b.id = _id AND b.status = 'draft'
    RETURNING b.id INTO _out;
    IF _out IS NULL THEN
      RAISE EXCEPTION 'only a draft or template can be edited' USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN _out;
END
$fn$;

-- ── 8. admin: send now (_at NULL) or at a time; cancel; delete ────────────
CREATE FUNCTION public.admin_push_broadcast_schedule(_id bigint, _at timestamptz DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me  uuid := auth.uid();
  _b   public.push_broadcasts%ROWTYPE;
  _run timestamptz := coalesce(_at, now());
  _job bigint;
BEGIN
  IF NOT public.has_role(_me, 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _b FROM public.push_broadcasts WHERE id = _id FOR UPDATE;
  IF NOT FOUND OR _b.kind <> 'message' OR _b.status <> 'draft' THEN
    RAISE EXCEPTION 'only a saved draft message can be sent' USING ERRCODE = '22023';
  END IF;
  IF _run < now() - interval '1 minute' OR _run > now() + interval '60 days' THEN
    RAISE EXCEPTION 'pick a time from now up to 60 days ahead' USING ERRCODE = '22023';
  END IF;
  IF _b.countdown_until IS NOT NULL
     AND (_b.countdown_until <= _run + interval '5 minutes' OR _b.countdown_until > _run + interval '30 days') THEN
    RAISE EXCEPTION 'the countdown must end 5 minutes to 30 days after the send time' USING ERRCODE = '22023';
  END IF;
  IF _at IS NOT NULL AND _at > now() + interval '1 minute'
     AND NOT coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false) THEN
    RAISE EXCEPTION 'scheduling is off on this site (job engine switch) — send now instead' USING ERRCODE = '22023';
  END IF;
  _job := public.job_enqueue('push.broadcast', jsonb_build_object('broadcast_id', _id), 'broadcast:' || _id, _run);
  UPDATE public.push_broadcasts
     SET status = 'scheduled', scheduled_at = _run, job_id = _job, sent_by = _me, updated_at = now()
   WHERE id = _id;
  RETURN _run;
END
$fn$;

CREATE FUNCTION public.admin_push_broadcast_cancel(_id bigint)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _job bigint;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  UPDATE public.push_broadcasts SET status = 'cancelled', updated_by = auth.uid(), updated_at = now()
   WHERE id = _id AND status = 'scheduled'
  RETURNING job_id INTO _job;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  UPDATE public.jobs SET status = 'cancelled', finished_at = now(), updated_at = now()
   WHERE id = _job AND status = 'queued';
  RETURN true;
END
$fn$;

CREATE FUNCTION public.admin_push_broadcast_delete(_id bigint)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  hit boolean;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  DELETE FROM public.push_broadcasts WHERE id = _id AND status IN ('draft', 'cancelled') RETURNING true INTO hit;
  RETURN coalesce(hit, false);
END
$fn$;

-- ── 9. admin: the lists (history / scheduled / drafts / templates) ────────
CREATE FUNCTION public.admin_push_broadcasts(_view text, _limit integer DEFAULT 50, _offset integer DEFAULT 0)
RETURNS TABLE (
  id bigint, kind text, status text, stuck boolean, name text, title text, body text, image_url text,
  images text[], link text, countdown_until timestamptz, actions jsonb, audience jsonb,
  scheduled_at timestamptz, updated_at timestamptz, started_at timestamptz,
  created_by_name text, sent_by_name text,
  audience_members integer, reached_members integer, devices integer, delivered integer, failed integer,
  removed integer, opened integer, fail_reasons jsonb, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _view NOT IN ('history', 'scheduled', 'drafts', 'templates') THEN
    RAISE EXCEPTION 'view must be history, scheduled, drafts or templates' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT b.id, b.kind, b.status,
         (b.status = 'sending' AND b.started_at < now() - interval '15 minutes'),
         b.name, b.title, b.body, b.image_url, b.images, b.link, b.countdown_until, b.actions, b.audience,
         b.scheduled_at, b.updated_at, b.started_at,
         (SELECT p.full_name::text FROM public.profiles p WHERE p.id = b.created_by),
         (SELECT p.full_name::text FROM public.profiles p WHERE p.id = b.sent_by),
         b.audience_members, b.reached_members, b.devices, b.delivered, b.failed, b.removed, b.opened,
         b.fail_reasons,
         count(*) OVER ()
    FROM public.push_broadcasts b
   WHERE CASE _view
           WHEN 'history'   THEN b.kind = 'message' AND b.status IN ('sending', 'sent', 'failed', 'cancelled')
           WHEN 'scheduled' THEN b.kind = 'message' AND b.status = 'scheduled'
           WHEN 'drafts'    THEN b.kind = 'message' AND b.status = 'draft'
           ELSE                  b.kind = 'template'
         END
   ORDER BY CASE WHEN _view = 'scheduled' THEN b.scheduled_at END ASC NULLS LAST,
            coalesce(b.started_at, b.updated_at) DESC, b.id DESC
   LIMIT least(greatest(coalesce(_limit, 50), 1), 200) OFFSET greatest(coalesce(_offset, 0), 0);
END
$fn$;

-- ── 10. edge only: claim a due broadcast once, then record its outcome ────
-- true = claimed now (receipts written, counts set); false = not due,
-- cancelled, or already claimed — the caller sends nothing.
CREATE FUNCTION public.push_broadcast_claim(_id bigint)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _aud jsonb;
BEGIN
  UPDATE public.push_broadcasts b SET status = 'sending', started_at = now(), updated_at = now()
   WHERE b.id = _id AND b.status = 'scheduled' AND b.scheduled_at <= now() + interval '30 seconds'
  RETURNING b.audience INTO _aud;
  IF _aud IS NULL THEN
    RETURN false;
  END IF;

  -- one statement: a receipt per member with a device, and the counts
  WITH m AS (
    SELECT a.member_id FROM public.push_audience_members(_aud) a WHERE a.eligible
  ), ins AS (
    INSERT INTO public.notification_deliveries (user_id, type, channel, broadcast_id)
    SELECT DISTINCT t.user_id, 'broadcast', 'push', _id
      FROM public.push_tokens t JOIN m ON m.member_id = t.user_id
    RETURNING notification_deliveries.user_id AS uid
  )
  UPDATE public.push_broadcasts b
     SET audience_members = (SELECT count(*) FROM m),
         reached_members = (SELECT count(*) FROM ins),
         devices = (SELECT count(*) FROM public.push_tokens t2 JOIN ins i2 ON i2.uid = t2.user_id)
   WHERE b.id = _id;
  RETURN true;
END
$fn$;

-- the devices of a claimed broadcast, a page at a time (receipt id order)
CREATE FUNCTION public.push_broadcast_targets(_id bigint, _after bigint DEFAULT 0, _limit integer DEFAULT 500)
RETURNS TABLE (delivery_id bigint, member_id uuid, token text, caps text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT d.id, d.user_id, t.token, t.caps
    FROM public.notification_deliveries d
    JOIN public.push_tokens t ON t.user_id = d.user_id
   WHERE d.broadcast_id = _id AND d.status = 'sending' AND d.id > coalesce(_after, 0)
     AND d.id IN (SELECT d2.id FROM public.notification_deliveries d2
                   WHERE d2.broadcast_id = _id AND d2.status = 'sending' AND d2.id > coalesce(_after, 0)
                   ORDER BY d2.id LIMIT least(greatest(coalesce(_limit, 500), 1), 500))
   ORDER BY d.id
$fn$;

-- _results: [{"d": receipt id, "ok": n, "failed": n, "removed": n, "error": "CODE"}]
-- _error:   a short CODE when the send stopped part-way. Receipts it never
--           reached are then recorded as failed with that code (their phones
--           are counted as failed) instead of "no device".
CREATE FUNCTION public.push_broadcast_finish(_id bigint, _results jsonb, _error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _stop   text := nullif(left(btrim(coalesce(_error, '')), 40), '');
  _unsent integer := 0;
BEGIN
  IF _results IS NULL OR jsonb_typeof(_results) <> 'array' THEN
    RAISE EXCEPTION 'results must be a list' USING ERRCODE = '22023';
  END IF;
  IF _stop IS NOT NULL AND _stop !~ '^[A-Z0-9_ ]{1,40}$' THEN
    _stop := 'SEND_STOPPED';                  -- a code, never free text
  END IF;
  UPDATE public.notification_deliveries d
     SET status = CASE WHEN r.ok > 0 THEN 'sent' ELSE 'failed' END,
         devices_ok = greatest(r.ok, 0), devices_failed = greatest(r.failed, 0),
         devices_pruned = greatest(r.removed, 0),
         error = left(nullif(r.error, ''), 300), finished_at = now()
    FROM jsonb_to_recordset(_results) AS r(d bigint, ok integer, failed integer, removed integer, error text)
   WHERE d.id = r.d AND d.broadcast_id = _id AND d.status = 'sending';

  -- receipts with no result: the send stopped before them (_error), or the
  -- member's devices went away between claim and send (signed out)
  WITH rest AS (
    UPDATE public.notification_deliveries d
       SET status = CASE WHEN _stop IS NULL THEN 'no_device' ELSE 'failed' END,
           error = _stop, finished_at = now()
     WHERE d.broadcast_id = _id AND d.status = 'sending'
    RETURNING d.user_id AS uid
  )
  SELECT count(*) INTO _unsent
    FROM public.push_tokens t JOIN rest ON rest.uid = t.user_id
   WHERE _stop IS NOT NULL;

  UPDATE public.push_broadcasts b
     SET delivered = s.ok, failed = s.failed + _unsent, removed = s.removed,
         fail_reasons = s.reasons
                        || CASE WHEN _unsent > 0 THEN jsonb_build_object(_stop, _unsent) ELSE '{}'::jsonb END,
         status = CASE WHEN s.ok = 0 AND coalesce(b.devices, 0) > 0 THEN 'failed' ELSE 'sent' END,
         finished_at = now(), updated_at = now()
    FROM (SELECT coalesce(sum(greatest(r.ok, 0)), 0)::int AS ok,
                 coalesce(sum(greatest(r.failed, 0)), 0)::int AS failed,
                 coalesce(sum(greatest(r.removed, 0)), 0)::int AS removed,
                 coalesce((SELECT jsonb_object_agg(e.code, e.n) FROM (
                    SELECT left(x.error, 40) AS code, count(*) AS n
                      FROM jsonb_to_recordset(_results) AS x(error text)
                     WHERE coalesce(x.error, '') <> '' GROUP BY 1) e), '{}'::jsonb) AS reasons
            FROM jsonb_to_recordset(_results) AS r(ok integer, failed integer, removed integer)) s
   WHERE b.id = _id AND b.status = 'sending';
END
$fn$;

-- ── 11. members (new app builds): register a device with what it can show,
--       and report the permission answer ────────────────────────────────────
CREATE FUNCTION public.register_push_device(_token text, _platform text, _app_version text DEFAULT NULL,
                                            _caps text[] DEFAULT '{}'::text[])
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF _token IS NULL OR length(_token) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'token required' USING ERRCODE = '22023';
  END IF;
  IF _platform NOT IN ('ios', 'android', 'web') THEN
    RAISE EXCEPTION 'invalid platform' USING ERRCODE = '22023';
  END IF;
  IF cardinality(coalesce(_caps, '{}')) > 8
     OR EXISTS (SELECT 1 FROM unnest(coalesce(_caps, '{}')) c WHERE c !~ '^[a-z0-9_]{1,24}$') THEN
    RAISE EXCEPTION 'invalid caps' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.push_tokens (user_id, token, platform, app_version, caps)
  VALUES (auth.uid(), _token, _platform, nullif(_app_version, ''), coalesce(_caps, '{}'))
  ON CONFLICT (token) DO UPDATE
    SET user_id = auth.uid(), platform = EXCLUDED.platform, app_version = EXCLUDED.app_version,
        caps = EXCLUDED.caps, updated_at = now();
END
$fn$;

CREATE FUNCTION public.report_push_permission(_permission text, _platform text, _app_version text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF _permission NOT IN ('granted', 'denied', 'prompt') OR _platform NOT IN ('ios', 'android', 'web') THEN
    RAISE EXCEPTION 'invalid permission report' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.push_permission_state (user_id, permission, platform, app_version, updated_at)
  VALUES (auth.uid(), _permission, _platform, nullif(_app_version, ''), now())
  ON CONFLICT (user_id) DO UPDATE
    SET permission = EXCLUDED.permission, platform = EXCLUDED.platform,
        app_version = EXCLUDED.app_version, updated_at = now();
END
$fn$;

-- ── 12. grants ────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.admin_push_audience(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_push_broadcast_save(bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_push_broadcast_schedule(bigint, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_push_broadcast_cancel(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_push_broadcast_delete(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_push_broadcasts(text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_push_device(text, text, text, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_push_permission(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.push_broadcast_claim(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_broadcast_finish(bigint, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_broadcast_targets(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_broadcast_targets(bigint, bigint, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_push_audience(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_push_broadcast_save(bigint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_push_broadcast_schedule(bigint, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_push_broadcast_cancel(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_push_broadcast_delete(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_push_broadcasts(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_push_device(text, text, text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_push_permission(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.push_broadcast_claim(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.push_broadcast_finish(bigint, jsonb, text) TO service_role;

-- ── 13. post checks ───────────────────────────────────────────────────────
DO $post$
DECLARE
  n text;
  f oid;
BEGIN
  FOREACH n IN ARRAY ARRAY[
    'public.admin_push_audience(jsonb)', 'public.admin_push_broadcast_save(bigint, jsonb)',
    'public.admin_push_broadcast_schedule(bigint, timestamp with time zone)',
    'public.admin_push_broadcast_cancel(bigint)', 'public.admin_push_broadcast_delete(bigint)',
    'public.admin_push_broadcasts(text, integer, integer)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL OR NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=""'] FROM pg_proc WHERE oid = f) THEN
      RAISE EXCEPTION 'PC-1500-POST-001: % missing or not SECURITY DEFINER with search_path=""', n;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'PC-1500-POST-002: % EXECUTE must be authenticated only', n;
    END IF;
    IF position('has_role(' IN pg_get_functiondef(f)) = 0 OR position('Not authorized' IN pg_get_functiondef(f)) = 0 THEN
      RAISE EXCEPTION 'PC-1500-POST-003: % has no admin gate', n;
    END IF;
  END LOOP;
  FOREACH n IN ARRAY ARRAY['public.push_broadcast_claim(bigint)', 'public.push_broadcast_finish(bigint, jsonb, text)',
                           'public.push_broadcast_targets(bigint, bigint, integer)',
                           'public.push_audience_members(jsonb)', 'public.push_audience_check(jsonb)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL OR has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'PC-1500-POST-004: % missing or callable by a client role', n;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.broadcast'
                  AND handler = 'edge:send-broadcast-push' AND extra_headers_secret = 'jobs:edge:send-push') THEN
    RAISE EXCEPTION 'PC-1500-POST-005: job kind push.broadcast not registered as intended';
  END IF;
  IF public.push_audience_check('{"kind":"active","days":"7"}') <> '{"kind":"active","days":7}'::jsonb THEN
    RAISE EXCEPTION 'PC-1500-POST-006: audience check does not normalise';
  END IF;
END
$post$;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2100 · M10 — automatic word guard (no approval queue), link rule, member reports
-- Owner order 21 Nov 2026: manual one-by-one approval cannot work at any size. The guard decides
-- by itself; admins only look at what members REPORT.
--
--   1. Hold is gone. Word rules are 'block' (message refused, the sender is told to change the
--      words, the receiver never sees it) or 'help' (self-harm: goes through, sender sees the
--      helpline, ops alarm). The old 'hold' starter rules become 'block'; the political starter
--      rules are switched OFF (the Owner adds the words he wants on the Block list himself).
--   2. New accounts (< 7 days) cannot send web links (MSG-061). Admin accounts are exempt.
--   3. message_report(chat, reason, note) — a member in the chat reports it. One open report per
--      member per chat, 20 reports a day. admin_message_reports / admin_message_report_done /
--      admin_message_watchlist — admin only, for the Reports tab.
--
-- Rollback: supabase/rollback/20261118_2100_m10_auto_guard_reports_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2100_m10_auto_guard_reports.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_admin_word_add(text,text,text,text,text)') IS NULL OR to_regclass('public.message_word_rules') IS NULL THEN
    RAISE EXCEPTION 'M10-PRE-001: M2c (20261118_1400) is not applied';
  END IF;
  IF to_regclass('public.message_reports') IS NOT NULL THEN
    RAISE EXCEPTION 'M10-PRE-002: message_reports already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. no 'hold' any more ──────────────────────────────────────────────────
UPDATE public.message_word_rules SET active = false WHERE category = 'political' AND action = 'hold';
UPDATE public.message_word_rules SET action = 'block' WHERE action = 'hold';
ALTER TABLE public.message_word_rules DROP CONSTRAINT message_word_rules_action_check;
ALTER TABLE public.message_word_rules ADD CONSTRAINT message_word_rules_action_check CHECK (action IN ('block', 'help'));

CREATE OR REPLACE FUNCTION public.message_admin_word_add(_category text, _pattern text, _lang text, _action text, _reason text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _id bigint; _p text := btrim(coalesce(_pattern, ''));
BEGIN
  IF _category NOT IN ('abuse', 'threat', 'political', 'self_harm', 'abnormal') OR _action NOT IN ('block', 'help') THEN
    RAISE EXCEPTION 'MSGADM-006: bad category or action (block or help)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF char_length(_p) < 2 OR char_length(_p) > 200 THEN
    RAISE EXCEPTION 'MSGADM-006: a word or phrase of 2–200 characters is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  INSERT INTO public.message_word_rules (category, pattern, lang, action, added_by)
  VALUES (_category, _p, nullif(btrim(coalesce(_lang, '')), ''), _action, _uid) RETURNING id INTO _id;
  INSERT INTO public.message_control_log (actor_id, area, old_value, new_value, reason)
  VALUES (_uid, 'word_rule', NULL, format('add #%s %s/%s "%s"', _id, _category, _action, left(_p, 60)), btrim(_reason));
  RETURN _id;
END
$fn$;

-- ── 2. the guard: words + the new-account link rule ────────────────────────
CREATE OR REPLACE FUNCTION public.message_word_guard(_uid uuid, _body text)
RETURNS text                                  -- 'ok' | 'block' | 'help'
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _hit record;
  _txt text := lower(coalesce(_body, ''));
  _age numeric;
BEGIN
  -- new accounts cannot send links (spam), admins can
  IF _txt ~ '(https?://|www\.|\m[a-z0-9-]+\.(com|in|net|org|co|io|me|ly|app|xyz|info|biz)\M)'
     AND NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    SELECT extract(epoch FROM (now() - p.created_at)) / 86400 INTO _age FROM public.profiles p WHERE p.id = _uid;
    IF coalesce(_age, 0) < 7 THEN
      RAISE EXCEPTION 'MSG-061: new accounts cannot send links yet' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  SELECT r.id, r.action INTO _hit
    FROM public.message_word_rules r
   WHERE r.active
     AND CASE WHEN r.pattern ~ '^[\x20-\x7E]+$'
              THEN _txt ~ ('\m' || regexp_replace(lower(r.pattern), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
              ELSE position(lower(r.pattern) in _txt) > 0 END
   ORDER BY array_position(ARRAY['block', 'help'], r.action), r.id
   LIMIT 1;
  IF NOT FOUND THEN RETURN 'ok'; END IF;
  IF _hit.action = 'help' THEN
    INSERT INTO public.message_guard_events (user_id, rule_id, action) VALUES (_uid, _hit.id, 'help');
    PERFORM public.ops_alarm_set('messages:help', true,
      format('Messages word guard: %s self-harm hit(s) in the last 24 hours — review message_guard_events',
             (SELECT count(*) FROM public.message_guard_events e WHERE e.action = 'help' AND e.created_at > now() - interval '24 hours')),
      jsonb_build_object('latest_user_id', _uid, 'at', now()));
  END IF;
  RETURN _hit.action;
END
$fn$;

-- ── 3. member reports ──────────────────────────────────────────────────────
CREATE TABLE public.message_reports (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporter_id       uuid NOT NULL,
  conversation_id   uuid NOT NULL REFERENCES public.conversations (id) ON DELETE CASCADE,
  reported_user_id  uuid,                                  -- the other member of a direct chat; NULL for a group
  reason            text NOT NULL CHECK (reason IN ('spam', 'abuse', 'threat', 'nudity', 'other')),
  note              text CHECK (note IS NULL OR char_length(note) <= 500),
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  handled_by        uuid,
  handled_at        timestamptz,
  handled_note      text CHECK (handled_note IS NULL OR char_length(handled_note) <= 500)
);
-- P28: message_reports · a handful per day · one open report per member per chat; also the admin Reports tab reads open rows newest first
CREATE UNIQUE INDEX message_reports_one_open_idx ON public.message_reports (reporter_id, conversation_id) WHERE status = 'open';
-- P28: message_reports · a handful per day · the watch list counts one member's recent reports
CREATE INDEX message_reports_reported_idx ON public.message_reports (reported_user_id, created_at DESC);
-- P28: message_reports · a handful per day · the per-day report limit counts one reporter's recent rows; the chat FK cascade finds its rows
CREATE INDEX message_reports_reporter_idx ON public.message_reports (reporter_id, created_at DESC);
-- P28: message_reports · a handful per day · deleting a chat finds its reports
CREATE INDEX message_reports_conversation_idx ON public.message_reports (conversation_id);

ALTER TABLE public.message_reports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_reports FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_reports TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;
CREATE TRIGGER zz_account_state_guard BEFORE INSERT OR UPDATE OR DELETE ON public.message_reports
  FOR EACH ROW EXECUTE FUNCTION public.account_state_guard();

CREATE FUNCTION public.message_report(_conversation uuid, _reason text, _note text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := auth.uid(); _other uuid;
BEGIN
  IF _me IS NULL THEN
    RAISE EXCEPTION 'MSG-001: sign in to report' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.account_can_act(_me) THEN
    RAISE EXCEPTION 'ACCOUNT_UNDER_REVIEW' USING ERRCODE = 'insufficient_privilege',
      DETAIL = 'Your account is under review', HINT = 'support@50mmretina.com';
  END IF;
  IF _reason IS NULL OR _reason NOT IN ('spam', 'abuse', 'threat', 'nudity', 'other') THEN
    RAISE EXCEPTION 'MSG-070: choose a reason' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _conversation IS NULL OR NOT public.is_conversation_member(_conversation) THEN
    RAISE EXCEPTION 'MSG-071: you are not in this chat' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (SELECT count(*) FROM public.message_reports r WHERE r.reporter_id = _me AND r.created_at > now() - interval '24 hours') >= 20 THEN
    RAISE EXCEPTION 'MSG-072: too many reports today' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (SELECT c.kind FROM public.conversations c WHERE c.id = _conversation) = 'direct' THEN
    SELECT m.user_id INTO _other FROM public.conversation_members m WHERE m.conversation_id = _conversation AND m.user_id <> _me LIMIT 1;
  END IF;
  INSERT INTO public.message_reports (reporter_id, conversation_id, reported_user_id, reason, note)
  VALUES (_me, _conversation, _other, _reason, nullif(left(btrim(coalesce(_note, '')), 500), ''))
  ON CONFLICT (reporter_id, conversation_id) WHERE status = 'open' DO NOTHING;
  RETURN true;
END
$fn$;

-- admin reads / actions (admin only; no reason box — the Owner wants it simple)
CREATE FUNCTION public.admin_message_reports(_status text DEFAULT 'open')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can read the reports' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
            'id', r.id, 'status', r.status, 'reason', r.reason, 'note', r.note, 'created_at', r.created_at,
            'conversation_id', r.conversation_id,
            'reporter_id', r.reporter_id, 'reporter_name', rp.full_name,
            'reported_id', r.reported_user_id, 'reported_name', xp.full_name,
            'reports_30d', (SELECT count(*) FROM public.message_reports q WHERE q.reported_user_id = r.reported_user_id AND q.created_at > now() - interval '30 days'),
            'handled_at', r.handled_at, 'handled_note', r.handled_note) ORDER BY r.created_at DESC)
          FROM (SELECT * FROM public.message_reports WHERE status = coalesce(_status, 'open') ORDER BY created_at DESC LIMIT 200) r
          LEFT JOIN public.profiles rp ON rp.id = r.reporter_id
          LEFT JOIN public.profiles xp ON xp.id = r.reported_user_id), '[]'::jsonb);
END
$fn$;

CREATE FUNCTION public.admin_message_report_done(_id bigint, _note text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can close a report' USING ERRCODE = 'insufficient_privilege';
  END IF;
  UPDATE public.message_reports SET status = 'done', handled_by = _uid, handled_at = now(), handled_note = nullif(left(btrim(coalesce(_note, '')), 500), '')
   WHERE id = _id AND status = 'open';
  RETURN FOUND;
END
$fn$;

-- the watch list: members reported most in the last 30 days
CREATE FUNCTION public.admin_message_watchlist()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can read the watch list' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
            'user_id', w.reported_user_id, 'full_name', p.full_name, 'username', p.custom_url, 'avatar_url', p.avatar_url,
            'reports_30d', w.n, 'open_reports', w.open_n, 'reporters', w.reporters, 'last_report_at', w.last_at,
            'paused', coalesce((SELECT r.blocked_until > now() FROM public.message_member_rules r WHERE r.user_id = w.reported_user_id), false))
            ORDER BY w.open_n DESC, w.n DESC)
          FROM (SELECT q.reported_user_id, count(*) AS n, count(*) FILTER (WHERE q.status = 'open') AS open_n,
                       count(DISTINCT q.reporter_id) AS reporters, max(q.created_at) AS last_at
                  FROM public.message_reports q
                 WHERE q.reported_user_id IS NOT NULL AND q.created_at > now() - interval '30 days'
                 GROUP BY q.reported_user_id ORDER BY count(*) FILTER (WHERE q.status = 'open') DESC, count(*) DESC LIMIT 100) w
          LEFT JOIN public.profiles p ON p.id = w.reported_user_id), '[]'::jsonb);
END
$fn$;

-- ── 4. rights ──────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.message_word_guard(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_word_guard(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.message_admin_word_add(text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_admin_word_add(text, text, text, text, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.message_report(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_reports(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_report_done(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_watchlist() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_report(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_message_reports(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_message_report_done(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_message_watchlist() TO authenticated, service_role;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1310 · A1 — one account state + one server guard (switch OFF)
-- Owner decisions 15 Nov 2026 (plan Part 3): admin can put any account
-- "under review" any time, no time limit; a member under review can log in and
-- look but cannot do anything; a member's own delete request waits for admin
-- review (auto-approved after 180 days, A2).
--
-- Measured by PROBE A0 (staging run 43714051979): members can write 121 tables
-- through 597 write policies, of which 11 look at is_suspended / is_banned, and
-- 143 member-runnable SECURITY DEFINER functions write, of which 6 check them.
-- A suspended member can still post through the API today.
--
-- This file:
--   account_states       — one row per member not 'active' (no row = active).
--                          Separate from profiles, so a member's own profile
--                          rights can never clear it. Members read only their
--                          own row; nobody writes it except the functions below.
--   account_state_log    — every change: who, when, from → to, reason.
--                          Append-only (UPDATE / DELETE refused, even for admins).
--   account_can_act(uid) — the one rule: active state AND not is_suspended AND
--                          not is_banned.
--   account_state_guard  — ONE trigger function, attached BEFORE INSERT / UPDATE /
--                          DELETE to every public table a member can write, except
--                          the passive list below. It refuses when the signed-in
--                          actor (auth.uid()) may not act — whether the write comes
--                          straight from the app or through a SECURITY DEFINER
--                          function. Service-role / cron work (no auth.uid()) and
--                          admins acting on others are unaffected.
--   admin_set_account_state(user, state, reason) — admin only, reason required.
--   my_account_state()   — the member's own state for the app banner (A4).
-- Switch system_flags.account_state_guard = false: the guard is attached but
-- lets everything through until switched on (staging first).
--
-- Passive tables (never blocked — viewing, settings, safety, support):
--   push_tokens, user_devices, user_notifications, notification_preferences,
--   feed_events, feed_signal_events, feed_hidden_posts, feed_muted_authors,
--   feed_favourite_authors, search_recents, profile_views, story_views,
--   ad_impressions, ad_conversions, activity_logs, lesson_progress, user_blocks,
--   support_tickets, ticket_replies, email_send_log, email_send_state,
--   email_unsubscribe_tokens, suppressed_emails, newsletter_subscribers,
--   ai_chat_usage, account_states, account_state_log; and the side effects of
--   looking, counters and logs found by A0b (staging run 43716615565):
--   client_errors, client_telemetry, client_telemetry_quota,
--   feed_session_delivered, member_activity_minutes, notification_deliveries,
--   notification_quiet_hours, profile_stats, entry_score_cache,
--   competition_entry_counts, db_audit_logs, held_result_notifications,
--   notification_centre_log, raw_commitments.
-- Guarded = every table a member can write by row rule (A0: 121 on both lanes)
-- PLUS every table a member-runnable SECURITY DEFINER function writes (A0b),
-- minus the passive list.
--
-- Rollback: supabase/rollback/20261115_1310_a1_account_state_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261115_1310_a1_account_state.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.account_states') IS NOT NULL THEN
    RAISE EXCEPTION 'A1-PRE-001: public.account_states already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. switch (OFF) ────────────────────────────────────────────────────────
INSERT INTO public.system_flags (key, value) VALUES ('account_state_guard', false) ON CONFLICT (key) DO NOTHING;

-- ── 2. state + log ─────────────────────────────────────────────────────────
CREATE TABLE public.account_states (
  user_id               uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  state                 text NOT NULL CHECK (state IN ('active', 'under_review', 'deletion_requested')),
  reason                text,
  set_by                uuid,
  set_at                timestamptz NOT NULL DEFAULT now(),
  deletion_requested_at timestamptz,
  auto_approve_at       timestamptz
);
CREATE TABLE public.account_state_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid NOT NULL,
  from_state  text NOT NULL,
  to_state    text NOT NULL,
  reason      text,
  actor_id    uuid,
  created_at  timestamptz NOT NULL DEFAULT now()
);
-- P28: account_state_log · a few rows per reviewed member · admin review page lists one member's history newest first
CREATE INDEX account_state_log_user_idx ON public.account_state_log (user_id, created_at DESC);

ALTER TABLE public.account_states    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_state_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_states, public.account_state_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.account_states TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.account_states TO service_role;
GRANT SELECT, INSERT ON public.account_state_log TO service_role;
CREATE POLICY "account_states: own row" ON public.account_states
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

CREATE FUNCTION public.account_state_log_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $fn$
BEGIN
  RAISE EXCEPTION 'account_state_log is append-only' USING ERRCODE = 'insufficient_privilege';
END
$fn$;
CREATE TRIGGER account_state_log_append_only BEFORE UPDATE OR DELETE ON public.account_state_log
  FOR EACH ROW EXECUTE FUNCTION public.account_state_log_append_only();

-- ── 3. the one rule ────────────────────────────────────────────────────────
CREATE FUNCTION public.account_can_act(_uid uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT _uid IS NULL
      OR (NOT EXISTS (SELECT 1 FROM public.account_states s WHERE s.user_id = _uid AND s.state <> 'active')
          AND NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _uid AND (p.is_suspended OR coalesce(p.is_banned, false))));
$fn$;

-- ── 4. the one guard ───────────────────────────────────────────────────────
CREATE FUNCTION public.account_state_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := auth.uid();
BEGIN
  IF _uid IS NOT NULL
     AND coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'account_state_guard'), false)
     AND NOT public.account_can_act(_uid) THEN
    RAISE EXCEPTION 'ACCOUNT_UNDER_REVIEW'
      USING ERRCODE = 'insufficient_privilege',
            DETAIL  = 'Your account is under review',
            HINT    = 'support@50mmretina.com';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$fn$;

DO $attach$
DECLARE
  t text;
  _n int := 0;
  _passive text[] := ARRAY[
    'push_tokens', 'user_devices', 'user_notifications', 'notification_preferences',
    'feed_events', 'feed_signal_events', 'feed_hidden_posts', 'feed_muted_authors',
    'feed_favourite_authors', 'search_recents', 'profile_views', 'story_views',
    'ad_impressions', 'ad_conversions', 'activity_logs', 'lesson_progress', 'user_blocks',
    'support_tickets', 'ticket_replies', 'email_send_log', 'email_send_state',
    'email_unsubscribe_tokens', 'suppressed_emails', 'newsletter_subscribers',
    'ai_chat_usage', 'account_states', 'account_state_log',
    -- side effects of looking, counters and logs (A0b, staging run 43716615565)
    'client_errors', 'client_telemetry', 'client_telemetry_quota', 'feed_session_delivered',
    'member_activity_minutes', 'notification_deliveries', 'notification_quiet_hours', 'profile_stats',
    'entry_score_cache', 'competition_entry_counts', 'db_audit_logs', 'held_result_notifications',
    'notification_centre_log', 'raw_commitments'];
BEGIN
  FOR t IN
    WITH by_policy AS (
      SELECT p.tablename AS tbl FROM pg_policies p
       WHERE p.schemaname = 'public' AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
         AND p.roles && ARRAY['authenticated', 'public']::name[]
    ), by_definer AS (
      -- tables written by SECURITY DEFINER functions a member can run (these
      -- bypass row rules, so a guard attached by policy alone would miss them)
      SELECT lower(m[2]) AS tbl
        FROM pg_proc f JOIN pg_namespace fn ON fn.oid = f.pronamespace,
             regexp_matches(f.prosrc, '(insert\s+into|update|delete\s+from)\s+(?:public\.)?"?([a-z_][a-z0-9_]*)"?', 'gi') m
       WHERE fn.nspname = 'public' AND f.prosecdef AND has_function_privilege('authenticated', f.oid, 'EXECUTE')
    )
    SELECT DISTINCT x.tbl
      FROM (SELECT tbl FROM by_policy UNION SELECT tbl FROM by_definer) x
      JOIN pg_class c ON c.relname = x.tbl AND c.relkind IN ('r', 'p')
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE x.tbl <> ALL (_passive)
     ORDER BY 1
  LOOP
    EXECUTE format('CREATE TRIGGER zz_account_state_guard BEFORE INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.account_state_guard()', t);
    _n := _n + 1;
  END LOOP;
  RAISE NOTICE 'A1: account_state_guard attached to % table(s)', _n;
END
$attach$;

-- ── 5. admin: set a member's state ─────────────────────────────────────────
CREATE FUNCTION public.admin_set_account_state(_user_id uuid, _state text, _reason text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _actor uuid := auth.uid();
  _from text;
BEGIN
  IF _actor IS NULL OR NOT public.has_role(_actor, 'admin') THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _state NOT IN ('active', 'under_review') THEN
    RAISE EXCEPTION 'state must be active or under_review' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF coalesce(btrim(_reason), '') = '' THEN
    RAISE EXCEPTION 'a reason is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _user_id = _actor THEN
    RAISE EXCEPTION 'an admin cannot change their own account state' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = _user_id) THEN
    RAISE EXCEPTION 'no such member' USING ERRCODE = 'no_data_found';
  END IF;
  SELECT s.state INTO _from FROM public.account_states s WHERE s.user_id = _user_id FOR UPDATE;
  _from := coalesce(_from, 'active');
  IF _state = 'active' THEN
    DELETE FROM public.account_states WHERE user_id = _user_id;
  ELSE
    INSERT INTO public.account_states (user_id, state, reason, set_by, set_at)
    VALUES (_user_id, _state, left(_reason, 500), _actor, now())
    ON CONFLICT (user_id) DO UPDATE
      SET state = EXCLUDED.state, reason = EXCLUDED.reason, set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at,
          deletion_requested_at = NULL, auto_approve_at = NULL;
  END IF;
  INSERT INTO public.account_state_log (user_id, from_state, to_state, reason, actor_id)
  VALUES (_user_id, _from, _state, left(_reason, 500), _actor);
  RETURN _state;
END
$fn$;

-- ── 6. member: own state, for the banner ───────────────────────────────────
CREATE FUNCTION public.my_account_state()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN auth.uid() IS NULL THEN NULL
              WHEN public.account_can_act(auth.uid()) THEN 'active'
              ELSE 'under_review' END;
$fn$;

REVOKE ALL ON FUNCTION public.account_state_log_append_only() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.account_can_act(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.account_state_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_set_account_state(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_account_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.account_can_act(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_account_state(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.my_account_state() TO authenticated, service_role;

COMMIT;

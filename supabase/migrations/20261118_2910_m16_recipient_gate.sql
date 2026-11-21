-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2910 · M16 — the Message icon and the send door must ask about the OTHER member too (Owner, 21 Nov 2026)
--
-- Owner: "Monojit Dutta has no chat facility, still the chat icon came on his profile. The icon comes only for members who
-- have the chat facility — not for those who never had it or were withdrawn in Admin."
-- Cause: the profile icon looked only at the VIEWER (message_allowed_me) and the send door (message_send_core) only checked the
-- sender's switch — a member outside the admin list could be written to, and would be pulled into a feature they do not have.
--
--  1. message_can_reach(_user): may the caller start a chat with THIS member?  (yes only when that member is currently
--     allowed by the admin switch, is active, and no block either way). Answers yes/no only. The profile icon uses it.
--  2. message_send_core refuses a recipient the admin switch does not allow, with the existing MSG-011 ("this member cannot
--     receive messages"), so nothing can be sent to such a member by any path (text, photo, reply).
--     The function is patched in place from its stored definition (one condition added), so every other rule stays exactly as is.
--
-- Rollback: supabase/rollback/20261118_2910_m16_recipient_gate_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2910_m16_recipient_gate.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_upload_allowed()') IS NULL THEN
    RAISE EXCEPTION 'M16-PRE-001: 20261118_2900 is not applied';
  END IF;
  IF to_regprocedure('public.message_can_reach(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'M16-PRE-002: message_can_reach already exists — not re-applying';
  END IF;
  IF to_regprocedure('public.message_send_core(uuid,text,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'M16-PRE-003: message_send_core is missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. may I start a chat with this member? ────────────────────────────────
CREATE FUNCTION public.message_can_reach(_user uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL
     AND _user IS NOT NULL
     AND _user <> (SELECT auth.uid())
     AND public.account_can_act(_user)
     AND public.message_control_allows(_user)
     AND NOT EXISTS (SELECT 1 FROM public.user_blocks b
                      WHERE (b.blocker_id = (SELECT auth.uid()) AND b.blocked_id = _user)
                         OR (b.blocker_id = _user AND b.blocked_id = (SELECT auth.uid())));
$fn$;
REVOKE ALL ON FUNCTION public.message_can_reach(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_can_reach(uuid) TO authenticated, service_role;

-- ── 2. the send door: the recipient must have the chat facility ────────────
DO $patch$
DECLARE
  _def text := pg_get_functiondef('public.message_send_core(uuid,text,uuid,jsonb)'::regprocedure);
  _old constant text := 'OR NOT public.account_can_act(_to) THEN';
  _new constant text := 'OR NOT public.account_can_act(_to) OR NOT public.message_control_allows(_to) THEN';
BEGIN
  IF position(_old IN _def) = 0 THEN
    RAISE EXCEPTION 'M16-PRE-004: the recipient check of message_send_core was not found — nothing patched';
  END IF;
  IF position(_new IN _def) > 0 THEN
    RAISE EXCEPTION 'M16-PRE-005: message_send_core already checks the recipient switch';
  END IF;
  EXECUTE replace(_def, _old, _new);
END
$patch$;

COMMIT;

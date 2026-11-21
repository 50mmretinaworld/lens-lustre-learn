-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_3700 · M27 — group chat screens: the three reads the screens need + a fix (Owner list 21 Nov 2026)
--
--  The group database doors exist since 20261118_1900 (create / add / remove / leave / send). The screens also need:
--   message_groups_allowed_me()    — may THIS member use groups (admin groups switch ON, chat facility, own rule)? Shows the
--                                     "New group" button; the doors still check everything again.
--   message_group_friends()        — the caller's accepted friends who are reachable AND have the chat facility (the picker).
--   message_group_members(conv)    — the members of a group the caller belongs to (names, role).
--  FIX: message_group_can_take (who a group may take) ignored the admin chat switch, so a friend WITHOUT the chat facility could
--  have been pulled into a group. It now also requires message_control_allows(member).
--
-- Rollback: supabase/rollback/20261118_3700_m27_group_screens_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_3700_m27_group_screens.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_group_create(text,uuid[])') IS NULL THEN
    RAISE EXCEPTION 'M27-PRE-001: M6 (20261118_1900) is not applied';
  END IF;
  IF to_regprocedure('public.message_groups_allowed_me()') IS NOT NULL THEN
    RAISE EXCEPTION 'M27-PRE-002: message_groups_allowed_me already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DO $patch$
DECLARE
  _def text := pg_get_functiondef('public.message_group_can_take(uuid,uuid)'::regprocedure);
  _old constant text := 'AND public.account_can_act(_other)';
  _new constant text := 'AND public.account_can_act(_other) AND public.message_control_allows(_other)';
BEGIN
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'M27-PRE-003: message_group_can_take has an unexpected shape — nothing patched'; END IF;
  EXECUTE replace(_def, _old, _new);
END
$patch$;

CREATE FUNCTION public.message_groups_allowed_me()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL
     AND public.account_can_act((SELECT auth.uid()))
     AND coalesce((SELECT c.groups_enabled FROM public.message_control c), false)
     AND public.message_control_allows((SELECT auth.uid()))
     AND coalesce((SELECT r.groups_ok FROM public.message_member_rules r WHERE r.user_id = (SELECT auth.uid())), true);
$fn$;

CREATE FUNCTION public.message_group_friends()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid());
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('user_id', p.id, 'full_name', p.full_name, 'username', p.custom_url, 'avatar_url', p.avatar_url) ORDER BY p.full_name)
      FROM (SELECT DISTINCT CASE WHEN f.requester_id = _me THEN f.addressee_id ELSE f.requester_id END AS uid
              FROM public.friendships f WHERE f.status = 'accepted' AND (f.requester_id = _me OR f.addressee_id = _me)) fr
      JOIN public.profiles p ON p.id = fr.uid
     WHERE public.message_group_can_take(_me, fr.uid)
     LIMIT 300), '[]'::jsonb);
END
$fn$;

CREATE FUNCTION public.message_group_members(_conversation uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid());
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.conversation_members cm JOIN public.conversations c ON c.id = cm.conversation_id
                  WHERE cm.conversation_id = _conversation AND cm.user_id = _me AND c.kind = 'group') THEN
    RAISE EXCEPTION 'MSG-071: not your group' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('user_id', cm.user_id, 'role', cm.role, 'full_name', p.full_name, 'username', p.custom_url, 'avatar_url', p.avatar_url)
                     ORDER BY (cm.role = 'owner') DESC, cm.joined_at)
      FROM public.conversation_members cm LEFT JOIN public.profiles p ON p.id = cm.user_id
     WHERE cm.conversation_id = _conversation), '[]'::jsonb);
END
$fn$;

REVOKE ALL ON FUNCTION public.message_groups_allowed_me() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_group_friends() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_group_members(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_groups_allowed_me(), public.message_group_friends(), public.message_group_members(uuid) TO authenticated, service_role;

COMMIT;

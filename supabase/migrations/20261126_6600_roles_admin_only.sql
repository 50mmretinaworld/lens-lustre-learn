-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 20261126_6600 · A0 — ROLES AND BADGES ARE AN HONOUR (Owner, 26 Nov 2026): no member gives themselves a role,
-- and no member requests one. Only an admin grants.
-- Lanes: staging, production.
--
-- S10 · X1 (20261031_0609 / 0613) merged the permissive policies into one per action named x1_merged_<action>,
-- so the member's way in now lives inside those:
--   user_roles         x1_merged_insert = admin OR (own row AND 'registered_photographer')  → admin only
--   role_applications  x1_merged_insert = own row                                          → dropped
-- The pre-merge names are dropped too, for a database where the merge was rolled back.
-- Admin grants are untouched. user_badges is already admin-only. Database-side writers (handle_new_user's plain
-- 'user' role) run as definer and are not affected. Existing roles and applications are NOT touched.
--
-- Older app builds still send these inserts: the sign-up request is ignored by the app; the old "Upgrade to
-- Photographer" and "Apply" buttons show an error. That is the intended refusal.
--
-- Safe to run again. (The first run of this file on staging, 26 Nov, named only the pre-merge policies and
-- changed nothing; PROBE C1 caught it.)
--
-- Rollback: supabase/rollback/20261126_6600_roles_admin_only_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261126_6600_roles_admin_only.sql
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $a0$
DECLARE
  r record;
BEGIN
  -- what is there before, printed for the run log
  FOR r IN SELECT tablename, policyname, with_check FROM pg_policies
            WHERE schemaname = 'public' AND tablename IN ('user_roles', 'role_applications')
              AND permissive = 'PERMISSIVE' AND cmd IN ('INSERT', 'ALL') LOOP
    RAISE NOTICE 'A0 before: % / % / %', r.tablename, r.policyname, r.with_check;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'user_roles'
                AND policyname = 'x1_merged_insert') THEN
    ALTER POLICY x1_merged_insert ON public.user_roles
      WITH CHECK (public.has_role((SELECT auth.uid()), 'admin'::public.app_role));
  END IF;
END
$a0$;

DROP POLICY IF EXISTS "Users can self-assign photographer role" ON public.user_roles;
DROP POLICY IF EXISTS x1_merged_insert ON public.role_applications;
DROP POLICY IF EXISTS "Users can create applications" ON public.role_applications;

COMMIT;

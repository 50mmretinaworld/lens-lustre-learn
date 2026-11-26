-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 20261126_6600 · A0 — ROLES AND BADGES ARE AN HONOUR (Owner, 26 Nov 2026): no member gives themselves a role,
-- and no member requests one. Only an admin grants.
-- Lanes: staging, production.
--
-- Drops two permissive INSERT policies for signed-in members:
--   user_roles         "Users can self-assign photographer role"
--   role_applications  "Users can create applications"
-- Admin grants are untouched ("Admins can manage roles" on user_roles, "Admins can manage badges" on user_badges).
-- Database-side writers (handle_new_user's plain 'user' role) run as definer and are not affected.
-- Existing roles and existing applications are NOT touched.
--
-- Older app builds still send these inserts: the sign-up request is ignored by the app; the old "Upgrade to
-- Photographer" and "Apply" buttons show an error. That is the intended refusal.
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

DROP POLICY IF EXISTS "Users can self-assign photographer role" ON public.user_roles;
DROP POLICY IF EXISTS "Users can create applications" ON public.role_applications;

COMMIT;

-- ROLLBACK · 20261118_4400 · M34 admin app versions
-- Drops the four read-only functions. No table or data was changed by M34, so nothing else to restore.
-- The client hides the versions card and the App column when these functions are missing.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.admin_app_versions()') IS NULL THEN
    RAISE EXCEPTION 'M34-RB-001: admin_app_versions missing — M34 is not applied';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.admin_app_version_members(text, text, integer, integer);
DROP FUNCTION IF EXISTS public.admin_app_versions();
DROP FUNCTION IF EXISTS public.admin_member_apps(uuid[]);
DROP FUNCTION IF EXISTS public.member_app_rows(uuid[]);

DO $post$
BEGIN
  IF to_regprocedure('public.admin_app_versions()') IS NOT NULL
     OR to_regprocedure('public.admin_member_apps(uuid[])') IS NOT NULL
     OR to_regprocedure('public.admin_app_version_members(text, text, integer, integer)') IS NOT NULL
     OR to_regprocedure('public.member_app_rows(uuid[])') IS NOT NULL THEN
    RAISE EXCEPTION 'M34-RB-POST-001: a function is still there';
  END IF;
  RAISE NOTICE 'M34 rolled back — admin app version functions removed';
END
$post$;

COMMIT;

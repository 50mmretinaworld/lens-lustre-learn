-- ROLLBACK · 20261118_0900 · J5a — drop the two admin read functions (the page falls back to an error card).
BEGIN;
DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
DROP FUNCTION IF EXISTS public.admin_jobs_list(text, text, integer, bigint);
DROP FUNCTION IF EXISTS public.admin_jobs_overview();
COMMIT;

-- ROLLBACK · 20261117_1700 · push.send back to 20 running at once.
BEGIN;
DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
UPDATE public.job_kinds SET max_running = 20 WHERE kind = 'push.send';
COMMIT;

-- ROLLBACK · 20261116_1000 · J3c — the five cron jobs call cron_http_call
-- directly again (same schedule), the cron.* job kinds, their jobs, their
-- jobs:edge:<function> header copies, cron_run and the switch are removed.
BEGIN;
DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

DO $back$
DECLARE r record; _n int := 0;
BEGIN
  FOR r IN SELECT jobname, schedule FROM cron.job WHERE command ~ '^SELECT public\.cron_run\(' LOOP
    PERFORM cron.schedule(r.jobname, r.schedule, format('SELECT public.cron_http_call(%L);', r.jobname));
    _n := _n + 1;
  END LOOP;
  DELETE FROM vault.secrets WHERE name IN (
    SELECT extra_headers_secret FROM public.job_kinds WHERE kind LIKE 'cron.%' AND extra_headers_secret IS NOT NULL);
  DELETE FROM public.jobs WHERE kind LIKE 'cron.%';
  DELETE FROM public.job_kinds WHERE kind LIKE 'cron.%';
  RAISE NOTICE 'J3c rollback: % cron job(s) back on cron_http_call', _n;
END
$back$;

DROP FUNCTION IF EXISTS public.cron_run(text);
DELETE FROM public.system_flags WHERE key = 'job_engine_cron_http';
COMMIT;

-- ROLLBACK · 20261117_0900 · PRODUCTION ONLY · J3c switch OFF again (cron_run calls cron_http_call as before).
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'production' THEN
    RAISE EXCEPTION 'APPLY REFUSED — production-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;
UPDATE public.system_flags SET value = false WHERE key = 'job_engine_cron_http';
COMMIT;

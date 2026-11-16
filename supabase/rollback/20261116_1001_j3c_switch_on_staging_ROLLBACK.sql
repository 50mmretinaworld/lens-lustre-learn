-- ROLLBACK · 20261116_1001 · STAGING ONLY · J3c switch OFF again (cron_run calls cron_http_call as before).
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;
UPDATE public.system_flags SET value = false WHERE key = 'job_engine_cron_http';
COMMIT;

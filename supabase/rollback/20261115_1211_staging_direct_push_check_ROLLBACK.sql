-- ROLLBACK · 20261115_1211 · STAGING ONLY · push group back ON (state after 1210).
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;
UPDATE public.system_flags SET value = true WHERE key = 'job_engine_push';
COMMIT;

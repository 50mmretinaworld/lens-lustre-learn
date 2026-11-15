-- ROLLBACK · 20261115_1240 · PRODUCTION ONLY · live pushes back to the direct call.
-- Push jobs already sent are still settled by the tick (job_engine stays ON).
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'production' THEN
    RAISE EXCEPTION 'APPLY REFUSED — production-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;
UPDATE public.system_flags SET value = false WHERE key = 'job_engine_push';
COMMIT;

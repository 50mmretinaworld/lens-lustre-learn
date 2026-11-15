-- ROLLBACK · 20261115_1210 · STAGING ONLY · job engine + push group OFF again.
-- Pushes go back to today's direct call at once; jobs already queued stay in
-- the book (job_tick does nothing while job_engine is off).
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;
UPDATE public.system_flags SET value = false WHERE key IN ('job_engine', 'job_engine_push');
COMMIT;

-- ROLLBACK · 20261115_1220 · PRODUCTION ONLY · engine OFF again, canary job cancelled.
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'production' THEN
    RAISE EXCEPTION 'APPLY REFUSED — production-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;
UPDATE public.jobs SET status = 'cancelled', finished_at = now(), updated_at = now()
 WHERE kind = 'push.send' AND idempotency_key = 'canary:20261115_1220' AND status IN ('queued', 'running');
UPDATE public.system_flags SET value = false WHERE key = 'job_engine';
COMMIT;

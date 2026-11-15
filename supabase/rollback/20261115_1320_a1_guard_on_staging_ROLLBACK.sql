-- ROLLBACK · 20261115_1320 · STAGING ONLY · A1 guard OFF again.
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;
UPDATE public.system_flags SET value = false WHERE key = 'account_state_guard';
COMMIT;

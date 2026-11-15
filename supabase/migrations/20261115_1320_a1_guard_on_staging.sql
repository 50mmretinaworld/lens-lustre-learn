-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1320 · STAGING ONLY · A1 account-state guard ON
-- A1 PASS on staging (run 43721978255). Turns the guard on for staging so the
-- app is exercised with it before live (live waits for the A4 banner, so a
-- member under review sees "Your account is under review" instead of errors).
-- Effect on staging today: the 1 suspended and 1 banned member can look but not
-- write. Refuses on production.
-- Rollback: supabase/rollback/20261115_1320_a1_guard_on_staging_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF to_regclass('public.account_states') IS NULL THEN
    RAISE EXCEPTION 'A1-ON-001: 20261115_1310 is not applied on staging';
  END IF;
END $g$;
UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261116_0900 · PRODUCTION ONLY · A1 account-state guard ON
-- Staging has run with the guard ON since 15 Nov (20261115_1320, run 43726116664).
-- A4 (the "Your account is under review · Contact support@50mmretina.com" banner)
-- is on main (#1083), so a member under review sees why instead of errors.
-- Effect on live: members under review (today 1 suspended + 1 banned) can look
-- but not write. Every other member is unchanged.
-- Refuses on staging. Refuses when A1 (20261115_1310) is not applied.
-- Rollback: supabase/rollback/20261116_0900_a1_guard_on_production_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'production' THEN
    RAISE EXCEPTION 'APPLY REFUSED — production-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF to_regclass('public.account_states') IS NULL THEN
    RAISE EXCEPTION 'A1-ON-001: 20261115_1310 is not applied on production';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.system_flags WHERE key = 'account_state_guard') THEN
    RAISE EXCEPTION 'A1-ON-002: system_flags.account_state_guard is missing';
  END IF;
END $g$;
UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
DO $r$ DECLARE _n int; BEGIN
  SELECT count(*) INTO _n FROM public.account_states WHERE state <> 'active';
  RAISE NOTICE 'A1-ON production: guard = on; account_states rows (under review or asked to delete) = %', _n;
END $r$;
COMMIT;

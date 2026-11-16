-- ═══════════════════════════════════════════════════════════════════════════
-- 20261116_1001 · STAGING ONLY · J3c switch ON — the scheduled edge calls go
-- through the job engine on staging first. Live stays OFF until staging has
-- run clean (jobs done, no jobs:failed alarm) — then a production switch file.
-- Rollback: supabase/rollback/20261116_1001_j3c_switch_on_staging_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF to_regprocedure('public.cron_run(text)') IS NULL THEN
    RAISE EXCEPTION 'J3c-ON-001: 20261116_1000 is not applied on staging';
  END IF;
END $g$;
UPDATE public.system_flags SET value = true WHERE key = 'job_engine_cron_http';
COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261117_0900 · PRODUCTION ONLY · J3c switch ON — the five scheduled edge calls
-- (boosts, ad traffic, gift-credit expiry, backup reminder, re-engagement e-mails)
-- go through the job engine on live. Owner "yes, J3c switch on live" 17 Nov 2026.
-- Staging ran with the switch ON since 16 Nov (20261116_1001, run 43843250347):
-- jobs status 17 Nov (run 44080009353) cron.apply-scheduled-boosts 288 done /
-- 0 failed in 24 h, cron.expire-gift-credits 1 done / 0 failed.
-- Production has 20261116_1000 (run 43860021331) + PROBE J3c PASS 5 jobs (43860113378).
-- Rollback: supabase/rollback/20261117_0900_j3c_switch_on_production_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'production' THEN
    RAISE EXCEPTION 'APPLY REFUSED — production-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF to_regprocedure('public.cron_run(text)') IS NULL THEN
    RAISE EXCEPTION 'J3c-ON-001: 20261116_1000 is not applied on production';
  END IF;
  IF NOT coalesce((SELECT value FROM public.system_flags WHERE key = 'job_engine'), false) THEN
    RAISE EXCEPTION 'J3c-ON-002: job_engine is OFF on production — the engine must run first';
  END IF;
  IF (SELECT count(*) FROM public.job_kinds WHERE kind LIKE 'cron.%' AND enabled) <> 5 THEN
    RAISE EXCEPTION 'J3c-ON-003: expected 5 enabled cron.* job kinds on production';
  END IF;
END $g$;
UPDATE public.system_flags SET value = true WHERE key = 'job_engine_cron_http';
DO $n$ BEGIN
  RAISE NOTICE 'J3c-ON production: job_engine_cron_http = on; % cron job(s) run through cron_run',
    (SELECT count(*) FROM cron.job WHERE command ~ '^SELECT public\.cron_run\(');
END $n$;
COMMIT;

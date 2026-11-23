-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261123_4900 N5 speed dashboard + alarm. Lanes: staging, production.
-- Unschedules the hourly job, closes any open screen-speed alarm, drops both
-- functions. Telemetry rows are untouched (the app keeps reporting; nothing reads them).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'n5-screen-speed';
UPDATE public.ops_alarms SET closed_at = now(), last_seen_at = now()
 WHERE alarm_key LIKE 'screen-speed:%' AND closed_at IS NULL;
DROP FUNCTION IF EXISTS public.n5_screen_speed_alarms();
DROP FUNCTION IF EXISTS public.admin_screen_speed(integer);

DO $post$
BEGIN
  IF to_regprocedure('public.admin_screen_speed(integer)') IS NOT NULL
     OR to_regprocedure('public.n5_screen_speed_alarms()') IS NOT NULL
     OR EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'n5-screen-speed') THEN
    RAISE EXCEPTION 'N5-4900-RB-POST: not back to the pre-4900 state';
  END IF;
  RAISE NOTICE 'N5-4900 ROLLBACK: job unscheduled, screen-speed alarms closed, functions dropped';
END
$post$;

COMMIT;

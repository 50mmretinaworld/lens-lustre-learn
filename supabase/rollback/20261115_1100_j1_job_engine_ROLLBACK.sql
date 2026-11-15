-- ROLLBACK · 20261115_1100 · J1 + J2 job engine
-- Safe only while no group has been moved onto the engine (J3 not started):
-- refuses if any job kind other than PROBE leftovers is registered.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.job_kinds') IS NOT NULL AND EXISTS (SELECT 1 FROM public.job_kinds) THEN
    RAISE EXCEPTION 'J1-RB-001: job kinds are registered — move those groups back first (J3 rollbacks)';
  END IF;
END
$lane_guard$;

DO $unsched$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'job-engine-tick') THEN
    PERFORM cron.unschedule('job-engine-tick');
  END IF;
END
$unsched$;

REVOKE ALL ON FUNCTION public.job_tick() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.job_requeue(bigint) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.job_enqueue(text, jsonb, text, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.job_fail_attempt(bigint, text) FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.job_tick();
DROP FUNCTION public.job_requeue(bigint);
DROP FUNCTION public.job_enqueue(text, jsonb, text, timestamptz);
DROP FUNCTION public.job_fail_attempt(bigint, text);
DROP TABLE public.jobs;
DROP TABLE public.job_kinds;

DELETE FROM vault.secrets WHERE name = 'jobs:edge';
DELETE FROM public.system_flags WHERE key = 'job_engine';
UPDATE public.ops_alarms SET closed_at = now(), last_seen_at = now()
 WHERE alarm_key IN ('jobs:failed', 'jobs:overdue') AND closed_at IS NULL;

COMMIT;

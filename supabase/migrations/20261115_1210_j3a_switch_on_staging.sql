-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1210 · STAGING ONLY · switch the job engine + push group ON (J3a test)
-- J3a PROBE passed on staging (run 43711235422). This file turns on
-- system_flags.job_engine and job_engine_push on STAGING so real pushes run
-- through the engine before live, and writes ONE check notification to a member
-- who has no registered device (send-push answers 200 "no devices registered",
-- so nobody's phone rings) — proving the full path: trigger → job → tick →
-- this lane's send-push with its vault header → 2xx → done.
-- Refuses on production.
-- Rollback: supabase/rollback/20261115_1210_j3a_switch_on_staging_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261115_1210_jobs_status.sql (read-only)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.send') THEN
    RAISE EXCEPTION 'J3a-ON-001: 20261115_1200 is not applied on staging';
  END IF;
END $g$;

UPDATE public.system_flags SET value = true WHERE key IN ('job_engine', 'job_engine_push');

INSERT INTO public.user_notifications (user_id, type, title, message, email_sent)
SELECT u.id, 'new_follower', 'System check', 'Background system test — please ignore.', true
  FROM auth.users u
 WHERE NOT EXISTS (SELECT 1 FROM public.notification_preferences np WHERE np.user_id = u.id)
   AND NOT EXISTS (SELECT 1 FROM public.push_tokens pt WHERE pt.user_id = u.id)
 ORDER BY u.created_at
 LIMIT 1;

COMMIT;

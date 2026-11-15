-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1211 · STAGING ONLY · does staging's OLD direct push path work?
-- The first engine push on staging got HTTP 401 from send-push (jobs status
-- PROBE run 43713869132). Before blaming the engine, measure today's path:
-- push group OFF (pushes go the old direct way), then ONE check notification
-- to a member with no device. PROBE_20261115_1211_recent_http_answers.sql then
-- shows send-push's answer. The engine itself stays ON. Refuses on production.
-- Rollback: supabase/rollback/20261115_1211_staging_direct_push_check_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'staging' THEN
    RAISE EXCEPTION 'APPLY REFUSED — staging-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END $g$;

UPDATE public.system_flags SET value = false WHERE key = 'job_engine_push';

INSERT INTO public.user_notifications (user_id, type, title, message, email_sent)
SELECT u.id, 'new_follower', 'System check', 'Background system test (direct path) — please ignore.', true
  FROM auth.users u
 WHERE NOT EXISTS (SELECT 1 FROM public.notification_preferences np WHERE np.user_id = u.id)
   AND NOT EXISTS (SELECT 1 FROM public.push_tokens pt WHERE pt.user_id = u.id)
 ORDER BY u.created_at
 LIMIT 1;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1220 · PRODUCTION ONLY · J3a canary — one engine push, no member touched
-- Staging's send-push answers 401 to the engine AND staging has recorded no
-- push receipts at all (J0): staging's push secret does not match its function
-- (a staging setup gap, not the engine). Live's direct pushes work (725 sent in
-- J0), and the engine copies its header from the same push_config row.
-- This file proves it on live WITHOUT moving members' pushes:
--   · job_engine ON (nothing else is on the engine; job_engine_push stays OFF,
--     so every member push keeps today's direct path),
--   · ONE push.send job for a member with no registered device and no settings
--     row — send-push answers 200 "no devices registered", so no phone rings.
-- Read back with PROBE_20261115_1210_jobs_status.sql: push.send done = header OK.
-- Refuses on staging.
-- Rollback: supabase/rollback/20261115_1220_j3a_production_canary_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'production' THEN
    RAISE EXCEPTION 'APPLY REFUSED — production-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.send') THEN
    RAISE EXCEPTION 'J3a-CAN-001: 20261115_1200 is not applied on production';
  END IF;
  IF coalesce((SELECT value FROM public.system_flags WHERE key = 'job_engine_push'), false) THEN
    RAISE EXCEPTION 'J3a-CAN-002: job_engine_push is already ON — this canary expects it OFF';
  END IF;
END $g$;

UPDATE public.system_flags SET value = true WHERE key = 'job_engine';

SELECT public.job_enqueue('push.send',
         jsonb_build_object('user_id', u.id, 'title', 'System check', 'body', 'Background system test',
                            'data', jsonb_build_object('type', 'system_check', 'reference_id', '')),
         'canary:20261115_1220')
  FROM auth.users u
 WHERE NOT EXISTS (SELECT 1 FROM public.notification_preferences np WHERE np.user_id = u.id)
   AND NOT EXISTS (SELECT 1 FROM public.push_tokens pt WHERE pt.user_id = u.id)
 ORDER BY u.created_at
 LIMIT 1;

COMMIT;

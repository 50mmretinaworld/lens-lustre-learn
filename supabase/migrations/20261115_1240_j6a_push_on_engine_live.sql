-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1240 · PRODUCTION ONLY · J6a — live pushes go through the job engine
-- Evidence before this switch:
--   J1 PASS production 43710225819 · J3a PASS production 43713697872 ·
--   canary push on the engine: done first try, HTTP 200 (20261115_1220,
--   PROBE run 43720264029) · J3b send-at-once PASS on staging 43723308060 and
--   on production (see the J3b carry) — a push leaves at once, as today.
-- From now: each live push is one job — sent the moment the notification is
-- written, 60 s to finish, retried 1/5/30 min, then the failed list + alarm.
-- Watch 48 h with PROBE_20261115_1210_jobs_status.sql; back out with the
-- rollback (pushes return to the direct call at once).
-- Refuses unless J3b is applied. Refuses on staging.
-- Rollback: supabase/rollback/20261115_1240_j6a_push_on_engine_live_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') <> 'production' THEN
    RAISE EXCEPTION 'APPLY REFUSED — production-only (p32.lane = %)', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF to_regprocedure('public.job_start(bigint)') IS NULL
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.push_on_notification()'::regprocedure) !~ 'job_start\(public\.job_enqueue' THEN
    RAISE EXCEPTION 'J6a-PRE-001: J3b (20261115_1230) is not applied on production';
  END IF;
END $g$;
UPDATE public.system_flags SET value = true WHERE key IN ('job_engine', 'job_engine_push');
COMMIT;

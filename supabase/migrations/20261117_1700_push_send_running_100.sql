-- ═══════════════════════════════════════════════════════════════════════════
-- 20261117_1700 · push.send may run 100 at once (was 20) — Owner "yes, push limit 100" 17 Nov 2026
--
-- Measured (production PROBE_20261117_1600_push_latency, run 44126737791):
--   17 Nov 12:54Z one post → 157 "new post" pushes in one minute;
--   17 Nov 13:00Z one mention-all → 152 pushes in one minute.
--   With max_running = 20 they queued: wait-to-start p90 363 s / 480 s, max 540 s,
--   and ordinary likes right after waited 300–360 s behind them. Outside the two
--   bursts every push started at once (wait 0 s). 363 done, 0 failed.
-- With 100: job_start sends the first 100 of a burst at once; the minute tick
-- (50 starts per tick, unchanged) sends the rest — a 157 burst clears in ~2 min.
-- Never sends twice (one job per notification, key notification:<id>; unchanged).
-- Both lanes. Rollback: supabase/rollback/20261117_1700_push_send_running_100_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261117_1700_push_send_running_100.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.send') THEN
    RAISE EXCEPTION 'PUSH100-PRE-001: job kind push.send (20261115_1200) is missing on this lane';
  END IF;
END
$lane_guard$;

UPDATE public.job_kinds SET max_running = 100 WHERE kind = 'push.send';

DO $post$
BEGIN
  IF (SELECT max_running FROM public.job_kinds WHERE kind = 'push.send') <> 100 THEN
    RAISE EXCEPTION 'PUSH100-POST-001: push.send max_running is not 100';
  END IF;
  RAISE NOTICE 'PUSH100: push.send max_running = 100 (lane %)', current_setting('p32.lane', true);
END
$post$;
COMMIT;

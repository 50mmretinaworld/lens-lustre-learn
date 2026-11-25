-- ═══════════════════════════════════════════════════════════════════════════
-- 5500 · GitHub repository move: point the in-database alarms at the new repo.
--
-- The repository moves from altisinfonet/lens-lustre-learn-Claude to
-- 50mmretinaworld/lens-lustre-learn (GitHub "Transfer ownership" + rename).
-- ops_monitor_tick() asks api.github.com/repos/<github_repo>/actions/... every
-- 5 minutes for the dead-man check. pg_net does not follow the 301 GitHub
-- returns for a moved repo, so without this the dead-man alarm would fire.
--
-- APPLY ONLY AFTER the transfer + rename are done (staging first, then
-- production). Changes one settings row and one column default — no member
-- data, no functions, no grants. Rollback: supabase/rollback/20261125_5500_ops_alarm_github_repo_move_ROLLBACK.sql
-- PROBE: supabase/migrations/PROBE_20261125_5500_ops_alarm_github_repo_move.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted' USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

ALTER TABLE public.ops_alarm_settings
  ALTER COLUMN github_repo SET DEFAULT '50mmretinaworld/lens-lustre-learn';

UPDATE public.ops_alarm_settings
   SET github_repo = '50mmretinaworld/lens-lustre-learn', updated_at = now()
 WHERE id = 1
   AND github_repo = 'altisinfonet/lens-lustre-learn-Claude';

DO $verify$
DECLARE _repo text;
BEGIN
  SELECT github_repo INTO _repo FROM public.ops_alarm_settings WHERE id = 1;
  IF _repo IS DISTINCT FROM '50mmretinaworld/lens-lustre-learn' THEN
    RAISE EXCEPTION 'APPLY FAILED — ops_alarm_settings.github_repo is %, expected 50mmretinaworld/lens-lustre-learn', _repo;
  END IF;
END
$verify$;

COMMIT;

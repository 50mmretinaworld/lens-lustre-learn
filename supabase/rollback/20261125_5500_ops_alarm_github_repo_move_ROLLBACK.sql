-- ROLLBACK for 20261125_5500_ops_alarm_github_repo_move.sql — points the
-- in-database alarms back at the old repository name. Use only if the GitHub
-- move is reversed. One settings row and one column default; no member data.
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
  ALTER COLUMN github_repo SET DEFAULT 'altisinfonet/lens-lustre-learn-Claude';

UPDATE public.ops_alarm_settings
   SET github_repo = 'altisinfonet/lens-lustre-learn-Claude', updated_at = now()
 WHERE id = 1
   AND github_repo = '50mmretinaworld/lens-lustre-learn';

COMMIT;

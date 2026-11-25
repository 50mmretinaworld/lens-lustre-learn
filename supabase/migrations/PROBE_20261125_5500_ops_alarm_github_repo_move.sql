-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 5500 · GitHub repository move for the in-database alarms. READ ONLY.
-- Prints the settings row, the column default and the latest GitHub checks
-- (workflow name, HTTP status) — no member data. Lane-asserted.
-- PASS = github_repo and default are 50mmretinaworld/lens-lustre-learn, and the
-- GitHub checks requested after the apply came back 200.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
END $g$;
\pset pager off
\pset format unaligned
\pset fieldsep '|'
SELECT 'OPS5500_LANE', current_setting('p32.lane'), now();
SELECT 'REPO', github_repo, updated_at,
       CASE WHEN github_repo = '50mmretinaworld/lens-lustre-learn' THEN 'PASS' ELSE 'FAIL' END
  FROM public.ops_alarm_settings WHERE id = 1;
SELECT 'DEFAULT', column_default,
       CASE WHEN column_default LIKE '%50mmretinaworld/lens-lustre-learn%' THEN 'PASS' ELSE 'FAIL' END
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'ops_alarm_settings' AND column_name = 'github_repo';
SELECT 'GHCHECK', kind, target, requested_at, ok, status_code, left(coalesce(error, ''), 80)
  FROM public.ops_probe_requests
 WHERE kind = 'gh_runs'
 ORDER BY id DESC LIMIT 10;
SELECT 'OPENALARM', alarm_key, left(coalesce(summary, ''), 100)
  FROM public.ops_alarms WHERE closed_at IS NULL;
ROLLBACK;

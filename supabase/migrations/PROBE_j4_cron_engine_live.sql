-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · J4 — the live half of the cron-engine ratchet (READ-ONLY).
-- The CI check (scripts/db-j4-cron-engine-check.mjs) sees only jobs written in
-- git; this reads cron.job on the lane itself, so a job made by hand is seen.
--   K1  every cron job is on the engine (SELECT public.cron_run('<job>');,
--       or job-engine-tick → job_tick) or on the frozen list below
--   K2  every cron_run job has its cron.<job> job kind (else switch ON would
--       quietly fall back to the old call)
--   K3  no cron job runs net.http_* or reads the vault in its own command
-- Commands are never printed (old ones carried secrets) — names only.
-- The list between the J4-ALLOW markers must equal
-- scripts/db-j4-cron-engine-allow.json "jobs" + "outside_git" (CI R6).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
DO $p$
DECLARE
  _allow text[] := ARRAY[
-- J4-ALLOW-BEGIN
    'competition-fullsize-retire',
    'emit-birthday-notifications',
    'first-post-reminders',
    'judging-invariants-nightly',
    'mark-expiring-post-drafts',
    'mention-groups-tick',
    'notification-delivery-alarm',
    'notification-stray-writer-check',
    'notification-weekly-summary',
    'ops-monitor-tick',
    'ops-video-alarms',
    'p1-backfill-last-seen',
    'p26-audit-retention',
    'process-email-queue',
    'process-post-jobs',
    'prune-client-errors',
    'prune-old-notifications',
    'publish-scheduled-posts',
    'purge-client-telemetry',
    'purge-cron-history',
    'purge-feed-signals',
    'purge-user-block-notices',
    'refresh-feed-scores',
    'rollup-engagement-daily',
    'stories-cleanup',
    'video-housekeeping',
    'video-orphan-sweep',
    'video-source-housekeeping',
    'video-source-unposted-cleanup'
-- J4-ALLOW-END
  ];
  _fail text[] := '{}';
  r record;
  _eng int := 0; _old int := 0; _f text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  FOR r IN SELECT jobname, command FROM cron.job ORDER BY jobname LOOP
    IF btrim(r.command) = format('SELECT public.cron_run(%L);', r.jobname)
       OR (r.jobname = 'job-engine-tick' AND btrim(r.command) ~* '^select public\.job_tick\(\);?$') THEN
      _eng := _eng + 1;
      IF r.jobname <> 'job-engine-tick'
         AND NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'cron.' || r.jobname) THEN
        _fail := _fail || format('K2 %s runs cron_run but has no cron.%s job kind', r.jobname, r.jobname);
      END IF;
    ELSIF r.jobname = ANY (_allow) THEN
      _old := _old + 1;
    ELSE
      _fail := _fail || format('K1 %s is outside the job engine and not on the frozen list', r.jobname);
    END IF;
    IF r.command ~* '\mnet\s*\.\s*http_(post|get)\s*\(' OR r.command ~* '\mvault\s*\.\s*decrypted_secrets\M' THEN
      _fail := _fail || format('K3 %s calls HTTP or reads the vault in its own command', r.jobname);
    END IF;
  END LOOP;
  RAISE NOTICE 'J4 lane %: % cron job(s) on the engine, % on the frozen list', current_setting('p32.lane', true), _eng, _old;
  IF cardinality(_fail) > 0 THEN
    FOREACH _f IN ARRAY _fail LOOP RAISE NOTICE 'J4 FAIL item: %', _f; END LOOP;
    RAISE EXCEPTION 'J4 FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'J4 PASS (lane %) — every cron job is on the engine or on the frozen list', current_setting('p32.lane', true);
END
$p$;
ROLLBACK;

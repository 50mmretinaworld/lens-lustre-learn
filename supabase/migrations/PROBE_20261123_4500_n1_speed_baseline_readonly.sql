-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · N1 server-speed baseline (network system N1). READ ONLY, ROLLBACK.
-- Prints COUNTS and TIMINGS only: no row data, no member ids, no settings
-- values. Query texts from pg_stat_statements are already normalised ($1 …)
-- and are cut to 100 characters. Changes nothing. Applied only via
-- apply-migration.yml (staging or production).
--
-- Answers: (1) what real members wait for each timed call, per platform,
-- last 7 days (client_telemetry); (2) which database statements cost the
-- most server time and their mean (pg_stat_statements); (3) cache hit ratio
-- and compute hints, so a "server is slow" claim is measured, not guessed.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '120s';

DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
END $g$;

\pset pager off
\pset format unaligned
\pset fieldsep '|'

SELECT 'N1_LANE', current_setting('p32.lane'), now(),
       (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database());

-- 1. Real member timings, last 7 days, per metric x platform.
SELECT 'N1_CLIENT', c.metric, c.platform, count(*) AS n,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p50,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p75,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p95,
       round(100.0 * count(*) FILTER (WHERE NOT c.ok) / count(*), 1) AS fail_pct
  FROM public.client_telemetry c
 WHERE c.kind = 'timing' AND c.created_at > now() - interval '7 days'
 GROUP BY 2, 3 ORDER BY 2, 3;

-- 1b. Same, per day for the feed call only (trend).
SELECT 'N1_FEED_DAY', (c.created_at AT TIME ZONE 'UTC')::date, c.platform, count(*),
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::integer,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::integer
  FROM public.client_telemetry c
 WHERE c.kind = 'timing' AND c.metric = 'rpc.get_broadcast_feed'
   AND c.created_at > now() - interval '7 days'
 GROUP BY 2, 3 ORDER BY 2, 3;

-- 2. Cache hit ratio + compute hints.
SELECT 'N1_DB', round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
       xact_commit, numbackends,
       (SELECT setting FROM pg_settings WHERE name = 'max_connections'),
       (SELECT setting || unit FROM pg_settings WHERE name = 'shared_buffers'),
       pg_size_pretty(pg_database_size(current_database()))
  FROM pg_stat_database WHERE datname = current_database();

-- 3. Top statements by total server time (normalised text, 100 chars).
DO $s$
DECLARE r record;
BEGIN
  IF to_regclass('extensions.pg_stat_statements') IS NULL THEN
    RAISE NOTICE 'N1_STMT none: pg_stat_statements not installed';
    RETURN;
  END IF;
  FOR r IN EXECUTE $q$
    SELECT calls, round(mean_exec_time::numeric, 1) AS mean_ms,
           round(max_exec_time::numeric, 0) AS max_ms,
           round(total_exec_time::numeric / 1000, 0) AS total_s,
           left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS q
      FROM extensions.pg_stat_statements
     WHERE calls > 20
     ORDER BY total_exec_time DESC LIMIT 30 $q$
  LOOP
    RAISE NOTICE 'N1_STMT|%|%|%|%|%', r.calls, r.mean_ms, r.max_ms, r.total_s, r.q;
  END LOOP;
END $s$;

-- 4. App functions by mean time (needs track_functions; -1 when off).
SELECT 'N1_FN', current_setting('track_functions');
SELECT 'N1_FN', p.proname, s.calls, round((s.total_time / nullif(s.calls, 0))::numeric, 1) AS mean_ms,
       round((s.self_time / nullif(s.calls, 0))::numeric, 1) AS self_mean_ms
  FROM pg_stat_user_functions s JOIN pg_proc p ON p.oid = s.funcid
 WHERE s.schemaname = 'public' AND s.calls > 20
 ORDER BY s.total_time DESC LIMIT 25;

ROLLBACK;

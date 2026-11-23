-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · N1 server-speed baseline, part 2: WHICH app functions cost the most.
-- READ ONLY, ROLLBACK. PROBE 4500 cut every PostgREST statement at 100
-- characters, before the function name. This one prints the function or table
-- NAME taken from the normalised text (no parameter values exist in it), with
-- calls, mean / max ms and total seconds. Changes nothing. apply-migration.yml only.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '120s';

DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
END $g$;

DO $s$
DECLARE r record;
BEGIN
  IF to_regclass('extensions.pg_stat_statements') IS NULL THEN
    RAISE NOTICE 'N1B none: pg_stat_statements not installed';
    RETURN;
  END IF;
  -- App calls through the API (PostgREST), grouped by the function / table they hit.
  FOR r IN EXECUTE $q$
    WITH s AS (
      SELECT calls, total_exec_time, mean_exec_time, max_exec_time,
             CASE
               WHEN query ~ 'pgrst_call' THEN 'rpc:' || coalesce((regexp_match(query, '"public"\."([a-z0-9_]+)"\('))[1], '?')
               WHEN query ~ '^WITH pgrst_source AS \( *(SELECT|INSERT|UPDATE|DELETE)'
                 THEN lower((regexp_match(query, '^WITH pgrst_source AS \( *(SELECT|INSERT|UPDATE|DELETE)'))[1]) || ':'
                      || coalesce((regexp_match(query, '"public"\."([a-z0-9_]+)"'))[1], '?')
               ELSE NULL
             END AS what
        FROM extensions.pg_stat_statements
    )
    SELECT what, sum(calls)::bigint AS calls,
           round((sum(total_exec_time) / nullif(sum(calls), 0))::numeric, 1) AS mean_ms,
           round(max(max_exec_time)::numeric, 0) AS max_ms,
           round((sum(total_exec_time) / 1000)::numeric, 0) AS total_s
      FROM s WHERE what IS NOT NULL
     GROUP BY what HAVING sum(calls) > 20
     ORDER BY sum(total_exec_time) DESC LIMIT 40 $q$
  LOOP
    RAISE NOTICE 'N1B_API|%|%|%|%|%', r.what, r.calls, r.mean_ms, r.max_ms, r.total_s;
  END LOOP;
  -- Same list ordered by mean (what one member waits for on the server).
  FOR r IN EXECUTE $q$
    WITH s AS (
      SELECT calls, total_exec_time,
             CASE WHEN query ~ 'pgrst_call' THEN 'rpc:' || coalesce((regexp_match(query, '"public"\."([a-z0-9_]+)"\('))[1], '?') END AS what
        FROM extensions.pg_stat_statements
    )
    SELECT what, sum(calls)::bigint AS calls, round((sum(total_exec_time) / nullif(sum(calls), 0))::numeric, 1) AS mean_ms
      FROM s WHERE what IS NOT NULL
     GROUP BY what HAVING sum(calls) > 50
     ORDER BY 3 DESC LIMIT 20 $q$
  LOOP
    RAISE NOTICE 'N1B_SLOW|%|%|%', r.what, r.calls, r.mean_ms;
  END LOOP;
  -- Realtime change polling (the largest single cost in PROBE 4500).
  FOR r IN EXECUTE $q$
    SELECT calls, round(mean_exec_time::numeric, 1) AS mean_ms, round((total_exec_time / 1000)::numeric, 0) AS total_s
      FROM extensions.pg_stat_statements
     WHERE query ~ '^SELECT wal->>' ORDER BY total_exec_time DESC LIMIT 3 $q$
  LOOP
    RAISE NOTICE 'N1B_REALTIME|calls %|mean % ms|total % s', r.calls, r.mean_ms, r.total_s;
  END LOOP;
END $s$;

-- Realtime publication size (each table here is polled for every subscriber).
SELECT 'N1B_PUB', pubname, count(*) FROM pg_publication_tables GROUP BY pubname ORDER BY pubname;

ROLLBACK;

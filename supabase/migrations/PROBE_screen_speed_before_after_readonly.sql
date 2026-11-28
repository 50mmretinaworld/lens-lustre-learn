-- PROBE (READ ONLY, ends in ROLLBACK) — Owner 28 Nov: "slowness: no guessing, proved only".
-- Screen open times the app already records (client_telemetry, kind 'timing', metric 'screen.<name>'):
--   A · per day, 22 Nov → today (UTC days): how many opens, median and 90th-percentile time, share that failed.
--   B · today BEFORE vs AFTER the badge release #1328 (live 28 Nov 09:18 UTC), per screen.
--   C · 27 Nov 06:00–08:00 UTC per 10 minutes (the freeze window), all screens together.
-- Numbers only; no member ids.
BEGIN;
SET TRANSACTION READ ONLY;
DO $$
DECLARE
  r record;
  line text;
  cut constant timestamptz := '2026-11-28 09:18:00+00';
BEGIN
  line := '';
  FOR r IN
    SELECT to_char(date_trunc('day', created_at), 'DD Mon') AS d, count(*) AS n,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)) AS p50,
           round(percentile_cont(0.9) WITHIN GROUP (ORDER BY duration_ms)) AS p90,
           round(100.0 * count(*) FILTER (WHERE NOT ok) / count(*), 1) AS bad
      FROM public.client_telemetry
     WHERE kind = 'timing' AND metric LIKE 'screen.%' AND metric NOT LIKE '%.cold' AND created_at >= '2026-11-22'
     GROUP BY 1, date_trunc('day', created_at) ORDER BY date_trunc('day', created_at)
  LOOP
    line := line || E'\n  ' || r.d || '  opens=' || r.n || '  median=' || r.p50 || ' ms  p90=' || r.p90 || ' ms  failed=' || r.bad || '%';
  END LOOP;
  RAISE NOTICE 'A · ALL SCREENS PER DAY (UTC):%', coalesce(nullif(line, ''), E'\n  (no rows)');

  line := '';
  FOR r IN
    SELECT metric,
           count(*) FILTER (WHERE created_at <  cut) AS n0,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms) FILTER (WHERE created_at <  cut)) AS b50,
           round(percentile_cont(0.9) WITHIN GROUP (ORDER BY duration_ms) FILTER (WHERE created_at <  cut)) AS b90,
           count(*) FILTER (WHERE created_at >= cut) AS n1,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms) FILTER (WHERE created_at >= cut)) AS a50,
           round(percentile_cont(0.9) WITHIN GROUP (ORDER BY duration_ms) FILTER (WHERE created_at >= cut)) AS a90
      FROM public.client_telemetry
     WHERE kind = 'timing' AND metric LIKE 'screen.%' AND metric NOT LIKE '%.cold'
       AND created_at >= cut - interval '24 hours'
     GROUP BY metric ORDER BY count(*) DESC LIMIT 15
  LOOP
    line := line || E'\n  ' || rpad(r.metric, 26) || 'before(24h) n=' || r.n0 || ' med=' || coalesce(r.b50::text, '-') || ' p90=' || coalesce(r.b90::text, '-')
                 || '  |  after n=' || r.n1 || ' med=' || coalesce(r.a50::text, '-') || ' p90=' || coalesce(r.a90::text, '-');
  END LOOP;
  RAISE NOTICE 'B · BEFORE vs AFTER #1328 (ms):%', coalesce(nullif(line, ''), E'\n  (no rows)');

  line := '';
  FOR r IN
    SELECT to_char(date_trunc('hour', created_at) + floor(extract(minute FROM created_at) / 10) * interval '10 min', 'HH24:MI') AS t,
           count(*) AS n,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)) AS p50,
           max(duration_ms) AS mx,
           count(*) FILTER (WHERE NOT ok) AS bad
      FROM public.client_telemetry
     WHERE kind = 'timing' AND metric LIKE 'screen.%' AND created_at >= '2026-11-27 06:00+00' AND created_at < '2026-11-27 08:00+00'
     GROUP BY 1 ORDER BY 1
  LOOP
    line := line || E'\n  ' || r.t || ' UTC  opens=' || r.n || '  median=' || r.p50 || ' ms  max=' || r.mx || ' ms  failed=' || r.bad;
  END LOOP;
  RAISE NOTICE 'C · FREEZE WINDOW 27 Nov per 10 min:%', coalesce(nullif(line, ''), E'\n  (no rows)');
END $$;
ROLLBACK;

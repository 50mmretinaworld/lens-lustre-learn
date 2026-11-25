-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · how fast real members' screens open (N5 timings). READ ONLY, ROLLBACK.
-- Owner, 25 Nov 2026: "after your network job the site became slow opening
-- everything". Prints, from public.client_telemetry (kind = 'timing'):
--   A  per day × screen × cold/warm × platform: opens, p50, p75, p95 (ms),
--      last 4 days — the same numbers Admin → App health → Speed per screen shows.
--   B  every other timing metric recorded in the last 2 days with its p50/p95,
--      so a slow request type shows up even if it is not a screen.
-- Counts and milliseconds only — never who. Changes nothing.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE r record; line text := '';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  IF to_regclass('public.client_telemetry') IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL: public.client_telemetry missing';
  END IF;

  FOR r IN
    SELECT (c.created_at AT TIME ZONE 'Asia/Kolkata')::date AS day,
           split_part(c.metric, '.', 2) AS screen,
           CASE WHEN c.metric LIKE '%.cold' THEN 'cold' ELSE 'warm' END AS kind,
           coalesce(c.platform, '?') AS platform,
           count(*) AS n,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p50,
           round(percentile_cont(0.75) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p75,
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p95
      FROM public.client_telemetry c
     WHERE c.kind = 'timing' AND c.metric LIKE 'screen.%'
       AND c.created_at >= now() - interval '4 days'
     GROUP BY 1, 2, 3, 4
     ORDER BY 1 DESC, 2, 3, 4
  LOOP
    line := line || format(E'\n  %s %-16s %-4s %-8s n=%-5s p50=%-6s p75=%-6s p95=%s',
                           r.day, r.screen, r.kind, r.platform, r.n, r.p50, r.p75, r.p95);
  END LOOP;
  RAISE NOTICE 'A · SCREEN SPEED (lane %, IST days):%', current_setting('p32.lane'), coalesce(nullif(line, ''), E'\n  (no screen timings)');

  line := '';
  FOR r IN
    SELECT c.metric, coalesce(c.platform, '?') AS platform, count(*) AS n,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p50,
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p95
      FROM public.client_telemetry c
     WHERE c.kind = 'timing' AND c.metric NOT LIKE 'screen.%'
       AND c.created_at >= now() - interval '2 days'
     GROUP BY 1, 2
     ORDER BY 5 DESC NULLS LAST
     LIMIT 40
  LOOP
    line := line || format(E'\n  %-40s %-8s n=%-5s p50=%-6s p95=%s', r.metric, r.platform, r.n, r.p50, r.p95);
  END LOOP;
  RAISE NOTICE 'B · OTHER TIMINGS, last 2 days, slowest p95 first:%', coalesce(nullif(line, ''), E'\n  (none)');
END
$p$;

ROLLBACK;

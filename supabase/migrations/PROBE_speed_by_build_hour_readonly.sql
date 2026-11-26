-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · where did 26 Nov's slower requests come from? READ ONLY, ROLLBACK.
-- Owner, 26 Nov 2026: "app is not opening fast". From public.client_telemetry:
--   A  feed + stories requests per IST hour × platform, yesterday and today
--   B  the same requests per app build × platform, last 4 days
--   C  app starts and uncaught errors per day × platform × build, last 4 days
--   D  failed (ok = false) requests per day × metric × platform, last 4 days
--   E  "slow connection" reasons and native crash/ANR marks, last 4 days
-- Counts, build numbers and milliseconds only — never who. Changes nothing.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE r record; line text := '';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  FOR r IN
    SELECT to_char(c.created_at AT TIME ZONE 'Asia/Kolkata', 'MM-DD HH24') AS h,
           split_part(c.metric, '.', 2) AS m, c.platform, count(*) AS n,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p50,
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p95
      FROM public.client_telemetry c
     WHERE c.kind = 'timing' AND c.metric IN ('rpc.get_feed_page', 'rpc.get_feed_stories_bar')
       AND c.platform = 'android'
       AND c.created_at >= (date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata') - interval '1 day') AT TIME ZONE 'Asia/Kolkata'
     GROUP BY 1, 2, 3 ORDER BY 2, 1
  LOOP
    line := line || format(E'\n  %s %-22s %-8s n=%-4s p50=%-6s p95=%s', r.h, r.m, r.platform, r.n, r.p50, r.p95);
  END LOOP;
  RAISE NOTICE 'A · BY HOUR (IST), Android:%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT c.metric, c.platform, c.app_build,
           (c.created_at AT TIME ZONE 'Asia/Kolkata')::date AS day, count(*) AS n,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p50,
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p95
      FROM public.client_telemetry c
     WHERE c.kind = 'timing'
       AND c.metric IN ('rpc.get_feed_page', 'rpc.get_feed_stories_bar', 'rpc.get_public_roles_for_users', 'post.open')
       AND c.platform IN ('android', 'ios')
       AND c.created_at >= now() - interval '4 days'
     GROUP BY 1, 2, 3, 4 HAVING count(*) >= 3 ORDER BY 1, 2, 3, 4
  LOOP
    line := line || format(E'\n  %-34s %-8s %-8s %s n=%-4s p50=%-6s p95=%s', r.metric, r.platform, r.app_build, r.day, r.n, r.p50, r.p95);
  END LOOP;
  RAISE NOTICE 'B · BY APP BUILD:%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT (c.created_at AT TIME ZONE 'Asia/Kolkata')::date AS day, c.platform, c.app_build,
           count(*) FILTER (WHERE c.kind = 'session' AND c.metric = 'app.start') AS starts,
           count(*) FILTER (WHERE c.kind = 'error') AS errors
      FROM public.client_telemetry c
     WHERE c.kind IN ('session', 'error') AND c.created_at >= now() - interval '4 days'
     GROUP BY 1, 2, 3
    HAVING count(*) >= 3 ORDER BY 2, 1 DESC, 4 DESC
  LOOP
    line := line || format(E'\n  %s %-8s %-14s starts=%-5s errors=%s', r.day, r.platform, r.app_build, r.starts, r.errors);
  END LOOP;
  RAISE NOTICE 'C · STARTS AND ERRORS:%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT (c.created_at AT TIME ZONE 'Asia/Kolkata')::date AS day, c.metric, c.platform,
           count(*) FILTER (WHERE NOT c.ok) AS failed, count(*) AS n
      FROM public.client_telemetry c
     WHERE c.kind = 'timing' AND c.metric LIKE 'rpc.%' AND c.created_at >= now() - interval '4 days'
     GROUP BY 1, 2, 3
    HAVING count(*) FILTER (WHERE NOT c.ok) > 0 ORDER BY 1 DESC, 4 DESC
  LOOP
    line := line || format(E'\n  %s %-34s %-8s failed=%s of %s', r.day, r.metric, r.platform, r.failed, r.n);
  END LOOP;
  RAISE NOTICE 'D · FAILED REQUESTS:%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT (c.created_at AT TIME ZONE 'Asia/Kolkata')::date AS day, c.metric, c.platform, count(*) AS n
      FROM public.client_telemetry c
     WHERE (c.metric LIKE 'net.%' OR (c.kind = 'session' AND c.metric <> 'app.start'))
       AND c.created_at >= now() - interval '4 days'
     GROUP BY 1, 2, 3 ORDER BY 1 DESC, 4 DESC
  LOOP
    line := line || format(E'\n  %s %-34s %-8s n=%s', r.day, r.metric, r.platform, r.n);
  END LOOP;
  RAISE NOTICE 'E · SLOW-CONNECTION AND NATIVE EXIT MARKS:%', coalesce(nullif(line, ''), E'\n  (none)');
END
$p$;

ROLLBACK;

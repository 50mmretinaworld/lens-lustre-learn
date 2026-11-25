-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · request speed per DAY, before vs after the network work (N1 23 Nov,
-- N2–N6 24 Nov). READ ONLY, ROLLBACK. Owner 25 Nov: "after your network job
-- site became slow". From public.client_telemetry (kind = 'timing'), the last
-- 14 days (whatever is still kept), per IST day × metric × platform: n, p50, p95.
-- Only the metrics that matter for opening screens. Counts and ms only.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE r record; line text := ''; oldest timestamptz;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  SELECT min(created_at) INTO oldest FROM public.client_telemetry WHERE kind = 'timing';
  FOR r IN
    SELECT (c.created_at AT TIME ZONE 'Asia/Kolkata')::date AS day, c.metric,
           coalesce(c.platform, '?') AS platform, count(*) AS n,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p50,
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::int AS p95
      FROM public.client_telemetry c
     WHERE c.kind = 'timing'
       AND c.created_at >= now() - interval '14 days'
       AND c.metric IN ('rpc.get_feed_stories_bar', 'rpc.get_feed_page', 'rpc.get_personal_feed',
                        'rpc.get_public_roles_for_users', 'rpc.get_post_view_counts', 'post.open',
                        'rpc.get_my_story_view_counts', 'rpc.get_broadcast_feed')
     GROUP BY 1, 2, 3
     ORDER BY 2, 3, 1
  LOOP
    line := line || format(E'\n  %-32s %-8s %s n=%-5s p50=%-6s p95=%s', r.metric, r.platform, r.day, r.n, r.p50, r.p95);
  END LOOP;
  RAISE NOTICE 'RPC SPEED BY DAY (lane %, oldest timing row kept: %):%', current_setting('p32.lane'), oldest,
    coalesce(nullif(line, ''), E'\n  (none)');
END
$p$;

ROLLBACK;

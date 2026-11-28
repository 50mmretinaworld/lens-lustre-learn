-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · WHEN did the database freeze, and what was it doing? READ ONLY, ROLLBACK.
-- Owner bug list 28 Nov (items 7, 8, 9, 10 autopsy): every cron job failed 7-8 times in 24 h with
-- max 11-13 s, and members' feed requests hit the 25 s timeout on 27 Nov 12:00 IST.
--   A  every failed or slow (> 5 s) cron run, last 3 days, IST time, seconds, first words of the error
--   B  10-minute windows (IST) where members' requests took > 15 s, last 3 days, with the app builds
--   C  right now: sessions running > 2 s, waiting events, and locks waited on (no query text with secrets)
-- Counts, times and job names only. The query filter never prints credentials (the Actions log is public).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE r record; line text := '';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  FOR r IN
    SELECT to_char(d.start_time AT TIME ZONE 'Asia/Kolkata', 'MM-DD HH24:MI:SS') AS t, j.jobname, d.status,
           round(extract(epoch FROM d.end_time - d.start_time)::numeric, 1) AS s,
           left(regexp_replace(coalesce(d.return_message, ''), '\s+', ' ', 'g'), 110) AS msg
      FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
     WHERE d.start_time > now() - interval '3 days'
       AND (d.status <> 'succeeded' OR d.end_time - d.start_time > interval '5 seconds')
       AND coalesce(d.return_message, '') !~* '(password|secret|token|apikey|api_key|bearer|jwt)'
     ORDER BY d.start_time
     LIMIT 120
  LOOP
    line := line || format(E'\n  %s %-28s %-10s %6ss %s', r.t, r.jobname, r.status, r.s, r.msg);
  END LOOP;
  RAISE NOTICE 'A · FAILED OR SLOW CRON RUNS (IST):%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT to_char(date_bin(interval '10 minutes', c.created_at, timestamptz '2026-01-01') AT TIME ZONE 'Asia/Kolkata', 'MM-DD HH24:MI') AS w,
           count(*) AS n, max(c.duration_ms) AS max_ms,
           string_agg(DISTINCT c.platform || ':' || coalesce(c.app_build, '?'), ' ') AS who
      FROM public.client_telemetry c
     WHERE c.kind = 'timing' AND c.duration_ms > 15000 AND c.created_at > now() - interval '3 days'
     GROUP BY 1 ORDER BY 1
  LOOP
    line := line || format(E'\n  %s n=%-4s max=%-6s %s', r.w, r.n, r.max_ms, r.who);
  END LOOP;
  RAISE NOTICE 'B · 10-MIN WINDOWS WITH REQUESTS OVER 15 s (IST):%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT a.state, a.wait_event_type, a.wait_event, a.backend_type,
           round(extract(epoch FROM now() - a.query_start)::numeric, 1) AS s,
           left(regexp_replace(a.query, '\s+', ' ', 'g'), 90) AS q
      FROM pg_stat_activity a
     WHERE a.pid <> pg_backend_pid() AND a.state IS DISTINCT FROM 'idle'
       AND a.query_start < now() - interval '2 seconds'
       AND a.query !~* '(password|secret|token|apikey|api_key|vault|decrypted|jwt|bearer)'
     ORDER BY a.query_start LIMIT 20
  LOOP
    line := line || format(E'\n  %-8s %-10s %-22s %-18s %6ss %s', r.state, r.wait_event_type, r.wait_event, r.backend_type, r.s, r.q);
  END LOOP;
  RAISE NOTICE 'C · RUNNING > 2 s NOW:%', coalesce(nullif(line, ''), E'\n  (none)');
END
$p$;

ROLLBACK;

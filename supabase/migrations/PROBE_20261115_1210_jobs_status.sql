-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1210 — job engine status (READ ONLY). Counts and masked
-- error snippets only, never payloads, ids of members or secrets.
-- Prints: switches, jobs per kind/status, last 24 h finished, oldest waiting,
-- last 5 distinct errors, open jobs:* alarms, and the old-path stuck pushes.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE r record;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'JS lane %', current_setting('p32.lane', true);
  FOR r IN SELECT key, value FROM public.system_flags WHERE key LIKE 'job_engine%' ORDER BY key LOOP
    RAISE NOTICE 'JS switch % = %', r.key, r.value;
  END LOOP;
  FOR r IN SELECT kind, status, count(*) AS n, max(attempts) AS max_att,
                  round(extract(epoch FROM now() - min(created_at)) / 60, 1) AS oldest_min
             FROM public.jobs GROUP BY 1, 2 ORDER BY 1, 2 LOOP
    RAISE NOTICE 'JS jobs % % n=% max_attempts=% oldest_min=%', r.kind, r.status, r.n, r.max_att, r.oldest_min;
  END LOOP;
  FOR r IN SELECT kind, count(*) FILTER (WHERE status = 'done') AS done, count(*) FILTER (WHERE status = 'failed') AS failed,
                  round(avg(extract(epoch FROM finished_at - created_at)) FILTER (WHERE status = 'done')::numeric, 1) AS avg_s
             FROM public.jobs WHERE finished_at > now() - interval '24 hours' GROUP BY 1 ORDER BY 1 LOOP
    RAISE NOTICE 'JS 24h % done=% failed=% avg_seconds_to_done=%', r.kind, r.done, r.failed, r.avg_s;
  END LOOP;
  FOR r IN SELECT kind, last_error, count(*) AS n FROM public.jobs WHERE last_error IS NOT NULL
            GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 5 LOOP
    RAISE NOTICE 'JS error x% % | %', r.n, r.kind, left(r.last_error, 120);
  END LOOP;
  FOR r IN SELECT alarm_key, summary, opened_at FROM public.ops_alarms WHERE alarm_key LIKE 'jobs:%' AND closed_at IS NULL LOOP
    RAISE NOTICE 'JS alarm OPEN % since % | %', r.alarm_key, r.opened_at, r.summary;
  END LOOP;
  FOR r IN SELECT status, count(*) AS n FROM public.notification_deliveries
            WHERE channel = 'push' AND created_at > now() - interval '24 hours' GROUP BY 1 ORDER BY 1 LOOP
    RAISE NOTICE 'JS push receipts 24h % n=%', r.status, r.n;
  END LOOP;
  RAISE NOTICE 'JS DONE';
END
$p$;

ROLLBACK;

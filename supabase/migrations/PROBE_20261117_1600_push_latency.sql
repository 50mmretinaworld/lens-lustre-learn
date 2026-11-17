-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261117_1600 — READ-ONLY: why push.send took 270 s on average
-- (production jobs status 44118548918, 17 Nov 15:49Z: 24 h done=353, failed=0).
-- Counts and times only — never user ids, titles or message text.
--   L1  per notification type: n, wait to start (started_at − created_at) and
--       time to done (finished_at − created_at): avg / p50 / p90 / max seconds
--   L2  the 15 busiest minutes by jobs created, with the type mix and how many
--       distinct members they went to
--   L3  per hour: created, avg wait to start, avg time to done
--   L4  attempts distribution and the running cap of the push.send kind
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
DO $p$
DECLARE r record; _since timestamptz := now() - interval '26 hours';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'PL lane % since %', current_setting('p32.lane', true), _since;
  FOR r IN
    SELECT coalesce(payload->'data'->>'type', '?') AS t, count(*) n,
           round(avg(extract(epoch FROM started_at - created_at))) w_avg,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM started_at - created_at))::numeric) w_p50,
           round(percentile_cont(0.9) WITHIN GROUP (ORDER BY extract(epoch FROM started_at - created_at))::numeric) w_p90,
           round(max(extract(epoch FROM started_at - created_at))) w_max,
           round(avg(extract(epoch FROM finished_at - created_at))) d_avg,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM finished_at - created_at))::numeric) d_p50,
           round(percentile_cont(0.9) WITHIN GROUP (ORDER BY extract(epoch FROM finished_at - created_at))::numeric) d_p90
      FROM public.jobs WHERE kind = 'push.send' AND created_at >= _since
     GROUP BY 1 ORDER BY 2 DESC
  LOOP
    RAISE NOTICE 'PL L1 type=% n=% | wait-to-start avg=% p50=% p90=% max=% | to-done avg=% p50=% p90=%',
      r.t, r.n, r.w_avg, r.w_p50, r.w_p90, r.w_max, r.d_avg, r.d_p50, r.d_p90;
  END LOOP;
  FOR r IN
    SELECT date_trunc('minute', created_at) m, count(*) n, count(DISTINCT payload->>'user_id') members,
           string_agg(DISTINCT coalesce(payload->'data'->>'type', '?'), ',') types,
           round(max(extract(epoch FROM started_at - created_at))) w_max
      FROM public.jobs WHERE kind = 'push.send' AND created_at >= _since
     GROUP BY 1 ORDER BY 2 DESC LIMIT 15
  LOOP
    RAISE NOTICE 'PL L2 minute=% n=% members=% types=% max-wait=%', r.m, r.n, r.members, r.types, r.w_max;
  END LOOP;
  FOR r IN
    SELECT date_trunc('hour', created_at) h, count(*) n,
           round(avg(extract(epoch FROM started_at - created_at))) w_avg,
           round(avg(extract(epoch FROM finished_at - created_at))) d_avg
      FROM public.jobs WHERE kind = 'push.send' AND created_at >= _since
     GROUP BY 1 ORDER BY 1
  LOOP
    RAISE NOTICE 'PL L3 hour=% n=% wait-avg=% done-avg=%', r.h, r.n, r.w_avg, r.d_avg;
  END LOOP;
  FOR r IN SELECT attempts, status, count(*) n FROM public.jobs
            WHERE kind = 'push.send' AND created_at >= _since GROUP BY 1, 2 ORDER BY 1, 2 LOOP
    RAISE NOTICE 'PL L4 attempts=% status=% n=%', r.attempts, r.status, r.n;
  END LOOP;
  FOR r IN SELECT max_running, timeout_seconds, max_attempts FROM public.job_kinds WHERE kind = 'push.send' LOOP
    RAISE NOTICE 'PL L4 kind push.send max_running=% timeout_s=% max_attempts=%', r.max_running, r.timeout_seconds, r.max_attempts;
  END LOOP;
  RAISE NOTICE 'PL DONE';
END
$p$;
ROLLBACK;

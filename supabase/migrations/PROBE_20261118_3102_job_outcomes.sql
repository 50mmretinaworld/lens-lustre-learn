-- PROBE · 20261118_3102 — job outcomes by kind over the last 7 days. READ-ONLY (changes nothing).
-- One NOTICE per (kind, status, last_error) with a count, newest activity first; always ends "OUTCOMES DONE".
-- Use: compare message.photo_purge with push.send (same edge secret) to tell a purge-only fault from a lane-wide one.
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE r record;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'OUTCOMES lane %  job_engine=%  job_engine_push=%', current_setting('p32.lane', true),
    (SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), (SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine_push');
  FOR r IN
    SELECT kind, status, left(coalesce(last_error, ''), 80) AS err, count(*) AS n, max(updated_at) AS last_seen
      FROM public.jobs WHERE created_at > now() - interval '7 days'
     GROUP BY kind, status, left(coalesce(last_error, ''), 80)
     ORDER BY max(updated_at) DESC LIMIT 40
  LOOP
    RAISE NOTICE '% | % | err=% | n=% | last=%', r.kind, r.status, r.err, r.n, r.last_seen;
  END LOOP;
  RAISE NOTICE 'OUTCOMES DONE';
END
$p$;

ROLLBACK;

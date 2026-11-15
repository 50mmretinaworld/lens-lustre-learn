-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1211 — recent pg_net answers (READ ONLY): status and the
-- first 80 characters of each distinct answer body in the last 20 minutes,
-- key-like strings masked. send-push answers are short JSON
-- ({"error":"Unauthorized"} / {"success":true,…}); nothing secret is in them.
-- Also: the engine's push jobs and their errors.
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
  RAISE NOTICE 'HA lane %', current_setting('p32.lane', true);
  FOR r IN SELECT coalesce(status_code::text, 'none') AS st, timed_out,
                  left(regexp_replace(coalesce(content, error_msg, ''), '[A-Za-z0-9_\-\.=+/]{20,}', '***', 'g'), 80) AS body,
                  count(*) AS n, max(created) AS last_at
             FROM net._http_response WHERE created > now() - interval '20 minutes'
            GROUP BY 1, 2, 3 ORDER BY 5 DESC LIMIT 15 LOOP
    RAISE NOTICE 'HA answer % timed_out=% x% last % | %', r.st, r.timed_out, r.n, r.last_at, r.body;
  END LOOP;
  FOR r IN SELECT status, attempts, last_error, run_at FROM public.jobs WHERE kind = 'push.send' ORDER BY id DESC LIMIT 5 LOOP
    RAISE NOTICE 'HA push job % attempts=% next=% | %', r.status, r.attempts, r.run_at, coalesce(r.last_error, '-');
  END LOOP;
  RAISE NOTICE 'HA DONE';
END
$p$;

ROLLBACK;

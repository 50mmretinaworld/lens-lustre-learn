-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261117_1700 — push.send runs up to 100 at once. One transaction,
-- ROLLBACK: pg_net sends queued requests only after COMMIT, so no push leaves.
-- Before 20261117_1700: FAIL (R1, max_running 20). After: PASS.
--   R1  push.send max_running = 100
--   R2  a burst of 30 push.send jobs: job_start starts all 30 at once (with 20,
--       10 of them would answer 'kind busy' — today's queueing), each with one
--       request and attempts = 1
--   R3  the same job started again → 'not due', no second request (never twice)
-- The fake jobs carry no member: user_id is a random uuid, nothing is sent.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;
DO $p$
DECLARE
  _fail text[] := '{}';
  _ids bigint[] := '{}';
  _id bigint; _r text; _busy int := 0; _run int; _req0 int; _req1 int; _free int; i int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'PUSH100 lane %', current_setting('p32.lane', true);
  -- R1
  IF coalesce((SELECT max_running FROM public.job_kinds WHERE kind = 'push.send'), 0) <> 100 THEN
    RAISE EXCEPTION 'PUSH100 FAIL: push.send max_running = % (want 100) — expected before 20261117_1700',
      (SELECT max_running FROM public.job_kinds WHERE kind = 'push.send');
  END IF;
  SELECT 100 - count(*) INTO _free FROM public.jobs WHERE kind = 'push.send' AND status = 'running';
  IF _free < 30 THEN
    RAISE NOTICE 'PUSH100 note: % push.send running right now — burst test skipped, run again later', 100 - _free;
  ELSE
    -- R2
    SELECT count(*) INTO _req0 FROM net.http_request_queue;
    FOR i IN 1..30 LOOP
      _id := public.job_enqueue('push.send',
               jsonb_build_object('user_id', gen_random_uuid(), 'title', 'PUSH100 PROBE', 'body', 'never sent',
                                  'data', jsonb_build_object('type', 'probe', 'reference_id', '')),
               'probe:push100:' || i);
      _ids := _ids || _id;
      _r := public.job_start(_id);
      IF _r = 'kind busy' THEN _busy := _busy + 1; END IF;
    END LOOP;
    SELECT count(*) INTO _run FROM public.jobs WHERE id = ANY (_ids) AND status = 'running' AND attempts = 1 AND net_request_id IS NOT NULL;
    SELECT count(*) INTO _req1 FROM net.http_request_queue;
    IF _busy > 0 OR _run <> 30 THEN
      _fail := _fail || format('R2 burst of 30: %s running, %s kind busy', _run, _busy);
    END IF;
    IF _req1 - _req0 <> 30 THEN _fail := _fail || format('R2 %s requests for 30 jobs', _req1 - _req0); END IF;
    -- R3
    _r := public.job_start(_ids[1]);
    SELECT count(*) INTO _req0 FROM net.http_request_queue;
    IF _r <> 'not due' OR _req0 <> _req1 THEN _fail := _fail || format('R3 second start answered %s', _r); END IF;
  END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'PUSH100 FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'PUSH100 FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'PUSH100 PASS (lane %) — push.send runs up to 100 at once; a burst of 30 starts at once, one request each; never twice',
    current_setting('p32.lane', true);
END
$p$;
ROLLBACK;

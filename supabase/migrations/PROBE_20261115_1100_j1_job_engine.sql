-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1100 — J1 + J2 job engine. One transaction, ROLLBACK:
-- every job, kind, flag change and planted HTTP answer below is thrown away.
-- Before 20261115_1100 is applied: FAIL (engine missing). After: J1 PASS.
--   A1-A4  members / signed-out visitors cannot read, add or run jobs
--   B1-B3  minute tick scheduled; switch exists and is OFF; OFF = nothing runs
--   C1     the same idempotency key never makes a second job
--   C2     SQL job → done
--   C3     failing job retried after 60 s, 300 s, 1800 s, then on the failed list
--   C4     the failed list raises alarm jobs:failed
--   C5     payload carrying a secret is refused
--   C6     stuck job (lease ran out) is freed and retried
--   C7     edge job is sent (request id kept) and the per-kind limit holds
--   C8     edge result 2xx → done, 500 → retry, no answer by lease → retry
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

CREATE FUNCTION pg_temp.as_role(_role text, _sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE _v text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', _role)::text, true);
    EXECUTE format('SET LOCAL ROLE %I', _role);
    EXECUTE _sql INTO _v;
    RAISE EXCEPTION 'PROBE_OK:%', coalesce(_v, '<no row>');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PROBE_OK:%' THEN RETURN 'ALLOWED ' || substr(SQLERRM, 10); END IF;
    RETURN 'refused ' || SQLSTATE;
  END;
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _id bigint; _id2 bigint; _n int; _j record; _t jsonb; _w numeric;
  _can_plant boolean := true;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'J1 lane %', current_setting('p32.lane', true);

  IF to_regclass('public.jobs') IS NULL OR to_regprocedure('public.job_tick()') IS NULL THEN
    RAISE EXCEPTION 'J1 FAIL: engine not installed (public.jobs / public.job_tick missing) — expected before 20261115_1100';
  END IF;

  -- A: no access for members or signed-out visitors
  FOREACH _r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF pg_temp.as_role(_r, 'SELECT count(*)::text FROM public.jobs') LIKE 'ALLOWED%' THEN _fail := _fail || ('A1 ' || _r || ' reads jobs'); END IF;
    IF pg_temp.as_role(_r, 'SELECT count(*)::text FROM public.job_kinds') LIKE 'ALLOWED%' THEN _fail := _fail || ('A2 ' || _r || ' reads job_kinds'); END IF;
    IF pg_temp.as_role(_r, $q$SELECT public.job_enqueue('x', '{}'::jsonb)::text$q$) LIKE 'ALLOWED%' THEN _fail := _fail || ('A3 ' || _r || ' enqueues'); END IF;
    IF pg_temp.as_role(_r, 'SELECT public.job_tick()::text') LIKE 'ALLOWED%' THEN _fail := _fail || ('A4 ' || _r || ' runs the tick'); END IF;
  END LOOP;
  RAISE NOTICE 'J1 A done';

  -- B: schedule + switch
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'job-engine-tick' AND active) THEN _fail := _fail || 'B1 no active job-engine-tick'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.system_flags WHERE key = 'job_engine') THEN _fail := _fail || 'B2 no job_engine flag'::text;
  ELSIF (SELECT value FROM public.system_flags WHERE key = 'job_engine') THEN RAISE NOTICE 'J1 B2 note: job_engine switch is ON on this lane'; END IF;

  CREATE FUNCTION public.j1_probe_ok(_p jsonb) RETURNS void LANGUAGE sql AS 'SELECT NULL::void';
  CREATE FUNCTION public.j1_probe_fail(_p jsonb) RETURNS void LANGUAGE plpgsql AS $b$ BEGIN RAISE EXCEPTION 'planted failure'; END $b$;
  REVOKE ALL ON FUNCTION public.j1_probe_ok(jsonb) FROM PUBLIC, anon, authenticated;
  REVOKE ALL ON FUNCTION public.j1_probe_fail(jsonb) FROM PUBLIC, anon, authenticated;
  INSERT INTO public.job_kinds (kind, handler) VALUES ('probe.ok', 'sql:public.j1_probe_ok'), ('probe.fail', 'sql:public.j1_probe_fail');
  INSERT INTO public.job_kinds (kind, handler, max_running, timeout_seconds) VALUES ('probe.edge', 'edge:j1-probe-target', 1, 30);

  UPDATE public.system_flags SET value = false WHERE key = 'job_engine';
  _id := public.job_enqueue('probe.ok', '{"n":1}'::jsonb);
  PERFORM public.job_tick();
  IF (SELECT status FROM public.jobs WHERE id = _id) <> 'queued' THEN _fail := _fail || 'B3 switch OFF but a job ran'::text; END IF;
  RAISE NOTICE 'J1 B done';

  UPDATE public.system_flags SET value = true WHERE key = 'job_engine';

  -- C1 idempotency
  _id := public.job_enqueue('probe.ok', '{"n":2}'::jsonb, 'probe-key-1');
  _id2 := public.job_enqueue('probe.ok', '{"n":3}'::jsonb, 'probe-key-1');
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'probe.ok' AND idempotency_key = 'probe-key-1';
  IF _id <> _id2 OR _n <> 1 THEN _fail := _fail || format('C1 same key made %s jobs', _n); END IF;

  -- C2 sql success (also drains the B3 job)
  PERFORM public.job_tick();
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'probe.ok' AND status <> 'done';
  IF _n <> 0 THEN _fail := _fail || format('C2 %s probe.ok job(s) not done', _n); END IF;

  -- C3 retry ladder then failed list
  _id := public.job_enqueue('probe.fail', '{}'::jsonb);
  FOREACH _w IN ARRAY ARRAY[60, 300, 1800]::numeric[] LOOP
    PERFORM public.job_tick();
    SELECT * INTO _j FROM public.jobs WHERE id = _id;
    IF _j.status <> 'queued' OR round(extract(epoch FROM _j.run_at - now())) <> _w OR _j.last_error NOT LIKE '%planted failure%' THEN
      _fail := _fail || format('C3 after attempt %s: status %s, wait %s s, error %s', _j.attempts, _j.status,
                               round(extract(epoch FROM _j.run_at - now())), coalesce(_j.last_error, '-'));
    END IF;
    UPDATE public.jobs SET run_at = now() - interval '1 second' WHERE id = _id;
  END LOOP;
  PERFORM public.job_tick();
  SELECT * INTO _j FROM public.jobs WHERE id = _id;
  IF _j.status <> 'failed' OR _j.attempts <> 4 THEN _fail := _fail || format('C3 final: status %s after %s attempts', _j.status, _j.attempts); END IF;
  RAISE NOTICE 'J1 C3 ladder: % after % attempts', _j.status, _j.attempts;

  -- C4 alarm
  IF NOT EXISTS (SELECT 1 FROM public.ops_alarms WHERE alarm_key = 'jobs:failed' AND closed_at IS NULL) THEN
    _fail := _fail || 'C4 no open jobs:failed alarm'::text;
  END IF;

  -- C5 secrets refused
  BEGIN
    PERFORM public.job_enqueue('probe.ok', '{"token":"abc"}'::jsonb);
    _fail := _fail || 'C5 payload with a token was accepted'::text;
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  -- C6 stuck job freed
  INSERT INTO public.jobs (kind, status, attempts, lease_until) VALUES ('probe.ok', 'running', 1, now() - interval '1 second')
  RETURNING id INTO _id;
  PERFORM public.job_tick();
  SELECT * INTO _j FROM public.jobs WHERE id = _id;
  IF _j.status <> 'queued' OR _j.last_error NOT LIKE 'stuck%' THEN _fail := _fail || format('C6 stuck job: %s / %s', _j.status, coalesce(_j.last_error, '-')); END IF;

  -- C7 edge send + per-kind limit (requests are rolled back, never sent)
  _id := public.job_enqueue('probe.edge', '{"n":1}'::jsonb);
  _id2 := public.job_enqueue('probe.edge', '{"n":2}'::jsonb);
  PERFORM public.job_tick();
  SELECT count(*) FILTER (WHERE status = 'running' AND net_request_id IS NOT NULL) INTO _n FROM public.jobs WHERE kind = 'probe.edge';
  IF _n <> 1 OR (SELECT count(*) FROM public.jobs WHERE kind = 'probe.edge' AND status = 'queued') <> 1 THEN
    _fail := _fail || format('C7 edge: %s running with a request id (want 1, limit 1)', _n);
  END IF;

  -- C8 settle from the real HTTP answer (planted answers)
  DELETE FROM public.jobs WHERE kind = 'probe.edge';
  INSERT INTO public.jobs (kind, status, attempts, lease_until, net_request_id) VALUES
    ('probe.edge', 'running', 1, now() + interval '1 minute', -910001),
    ('probe.edge', 'running', 1, now() + interval '1 minute', -910002),
    ('probe.edge', 'running', 1, now() - interval '1 second', -910003);
  BEGIN
    INSERT INTO net._http_response (id, status_code, content, timed_out) VALUES (-910001, 200, 'ok', false), (-910002, 500, 'boom', false);
  EXCEPTION WHEN insufficient_privilege THEN
    _can_plant := false;
    RAISE NOTICE 'J1 C8 note: cannot plant HTTP answers on this lane (no INSERT on net._http_response) — only the no-answer case is checked';
  END;
  UPDATE public.system_flags SET value = true WHERE key = 'job_engine';
  -- keep C8 isolated from the per-kind limit: raise it for this check
  UPDATE public.job_kinds SET max_running = 10 WHERE kind = 'probe.edge';
  PERFORM public.job_tick();
  IF _can_plant THEN
    IF coalesce((SELECT status FROM public.jobs WHERE net_request_id = -910001), '-') <> 'done' THEN
      _fail := _fail || 'C8 HTTP 200 did not finish the job'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'probe.edge' AND status = 'queued' AND last_error = 'HTTP 500') THEN
      _fail := _fail || 'C8 HTTP 500 was not retried'::text;
    END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'probe.edge' AND status = 'queued' AND last_error LIKE 'no answer%') THEN
    _fail := _fail || 'C8 no answer by the lease was not retried'::text;
  END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'J1 FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'J1 FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'J1 PASS (lane %) — members locked out; switch OFF = nothing runs; idempotent; retries 60/300/1800 s then failed + alarm; secrets refused; stuck freed; edge settled from the real HTTP answer%',
    current_setting('p32.lane', true), CASE WHEN _can_plant THEN '' ELSE ' (no-answer case only)' END;
END
$p$;

ROLLBACK;

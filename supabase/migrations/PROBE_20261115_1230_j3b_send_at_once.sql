-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1230 — J3b send at once. One transaction, ROLLBACK.
-- (Supersedes PROBE_20261115_1200 for the switched-ON case: since J3b the
-- engine's request leaves at once, so "no request at insert" no longer holds.)
-- Before 20261115_1230: FAIL (job_start missing). After: J3b PASS.
--   S1  switch OFF → today's single direct request, no job
--   S2  switch ON  → one push.send job, already RUNNING with its request id at
--                    the moment the notification is written (no tick needed);
--                    exactly one request queued, and it is the job's own
--   S3  that request: this lane's send-push, 60 s timeout, vault header present
--   S4  the same notification id again → still one job, no second request
--   S5  job_start on a job that is not due → 'not due', nothing sent
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _uid uuid; _nid text; _url text; _q0 int; _q1 int; _j record; _h jsonb; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'J3b lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.job_start(bigint)') IS NULL THEN
    RAISE EXCEPTION 'J3b FAIL: job_start missing — expected before 20261115_1230';
  END IF;

  SELECT function_url INTO _url FROM public.push_config LIMIT 1;
  SELECT u.id INTO _uid FROM auth.users u
   WHERE NOT EXISTS (SELECT 1 FROM public.notification_preferences np WHERE np.user_id = u.id)
   ORDER BY u.created_at LIMIT 1;
  IF _uid IS NULL THEN RAISE EXCEPTION 'J3b FAIL: no member without a notification settings row'; END IF;

  -- S1
  UPDATE public.system_flags SET value = false WHERE key = 'job_engine_push';
  UPDATE public.system_flags SET value = true WHERE key = 'job_engine';
  SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _url;
  INSERT INTO public.user_notifications (user_id, type, title, message, email_sent)
  VALUES (_uid, 'new_follower', 'J3b probe off', 'probe', true) RETURNING id INTO _nid;
  SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _url;
  IF _q1 - _q0 <> 1 THEN _fail := _fail || format('S1 switch OFF: %s request(s), want 1', _q1 - _q0); END IF;
  IF EXISTS (SELECT 1 FROM public.jobs WHERE idempotency_key = 'notification:' || _nid) THEN _fail := _fail || 'S1 job made with switch OFF'::text; END IF;

  -- S2
  UPDATE public.system_flags SET value = true WHERE key = 'job_engine_push';
  SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _url;
  INSERT INTO public.user_notifications (user_id, type, title, message, email_sent)
  VALUES (_uid, 'new_follower', 'J3b probe on', 'probe', true) RETURNING id INTO _nid;
  SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _url;
  SELECT * INTO _j FROM public.jobs WHERE kind = 'push.send' AND idempotency_key = 'notification:' || _nid;
  IF _j.id IS NULL THEN
    _fail := _fail || 'S2 no push.send job'::text;
  ELSE
    IF _j.status <> 'running' OR _j.net_request_id IS NULL OR _j.attempts <> 1 THEN
      _fail := _fail || format('S2 job not sent at once: %s, request %s, attempts %s', _j.status, coalesce(_j.net_request_id::text, '-'), _j.attempts);
    END IF;
    IF _q1 - _q0 <> 1 OR NOT EXISTS (SELECT 1 FROM net.http_request_queue q WHERE q.id = _j.net_request_id) THEN
      _fail := _fail || format('S2 %s request(s) queued, want exactly the job''s one', _q1 - _q0);
    END IF;
    -- S3
    SELECT headers INTO _h FROM net.http_request_queue WHERE id = _j.net_request_id;
    IF NOT EXISTS (SELECT 1 FROM net.http_request_queue q WHERE q.id = _j.net_request_id AND q.url = _url AND q.timeout_milliseconds = 60000) THEN
      _fail := _fail || 'S3 request is not this lane''s send-push with 60 s'::text;
    END IF;
    IF _h IS NULL OR coalesce(_h->>'x-internal-secret', '') = '' THEN _fail := _fail || 'S3 vault header missing'::text; END IF;
    -- S4
    SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _url;
    _r := public.job_start(public.job_enqueue('push.send', _j.payload, 'notification:' || _nid));
    SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _url;
    SELECT count(*) INTO _n FROM public.jobs WHERE idempotency_key = 'notification:' || _nid;
    IF _n <> 1 OR _q1 <> _q0 OR _r <> 'not due' THEN
      _fail := _fail || format('S4 repeat: %s job(s), %s new request(s), job_start=%s', _n, _q1 - _q0, _r);
    END IF;
  END IF;

  -- S5
  _r := public.job_start(public.job_enqueue('push.send', '{"user_id":"00000000-0000-0000-0000-000000000000"}'::jsonb,
                                            'j3b-probe-later', now() + interval '1 hour'));
  IF _r <> 'not due' THEN _fail := _fail || ('S5 future job started: ' || _r); END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'J3b FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'J3b FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'J3b PASS (lane %) — switch OFF = today''s direct push; switch ON = one keyed job sent at the moment the notification is written (60 s, vault header), never twice; future jobs wait',
    current_setting('p32.lane', true);
END
$p$;

ROLLBACK;

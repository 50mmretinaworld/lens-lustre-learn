-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1200 — J3a push on the job engine. One transaction,
-- ROLLBACK: the test notifications, jobs, switch flips and queued HTTP
-- requests below are thrown away (pg_net sends only after COMMIT).
-- Before 20261115_1200: FAIL (push.send kind missing). After: J3a PASS.
--   P1  group switch exists and is OFF on this lane
--   P2  switch OFF → a new notification sends exactly today's direct request, no job
--   P3  switch ON  → no direct request; one push.send job, keyed notification:<id>
--   P4  the job's payload holds no secret
--   P5  the tick sends it to this lane's send-push, 60 s timeout, with the
--       x-internal-secret header from the vault (value never printed)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _uid uuid; _nid text; _url text; _q0 int; _q1 int; _jid bigint; _j record; _h jsonb;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'J3a lane %', current_setting('p32.lane', true);
  IF to_regclass('public.job_kinds') IS NULL OR NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.send') THEN
    RAISE EXCEPTION 'J3a FAIL: push.send job kind missing — expected before 20261115_1200';
  END IF;

  -- P1
  IF NOT EXISTS (SELECT 1 FROM public.system_flags WHERE key = 'job_engine_push') THEN _fail := _fail || 'P1 no job_engine_push flag'::text;
  ELSIF (SELECT value FROM public.system_flags WHERE key = 'job_engine_push') THEN RAISE NOTICE 'J3a P1 note: push group switch is ON on this lane'; END IF;

  SELECT function_url INTO _url FROM public.push_config LIMIT 1;
  -- a member with no notification settings row: today's rules allow every push type
  SELECT u.id INTO _uid FROM auth.users u
   WHERE NOT EXISTS (SELECT 1 FROM public.notification_preferences np WHERE np.user_id = u.id)
   ORDER BY u.created_at LIMIT 1;
  IF _uid IS NULL THEN RAISE EXCEPTION 'J3a FAIL: no member without a notification settings row to test with'; END IF;

  -- P2 switch OFF
  UPDATE public.system_flags SET value = false WHERE key IN ('job_engine', 'job_engine_push');
  SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _url;
  INSERT INTO public.user_notifications (user_id, type, title, message, email_sent)
  VALUES (_uid, 'new_follower', 'J3a probe off', 'probe', true) RETURNING id INTO _nid;
  SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _url;
  IF _q1 - _q0 <> 1 THEN _fail := _fail || format('P2 switch OFF: %s direct request(s), want 1', _q1 - _q0); END IF;
  IF EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'push.send' AND idempotency_key = 'notification:' || _nid) THEN
    _fail := _fail || 'P2 switch OFF still made a job'::text;
  END IF;

  -- P3 switch ON
  UPDATE public.system_flags SET value = true WHERE key IN ('job_engine', 'job_engine_push');
  SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _url;
  INSERT INTO public.user_notifications (user_id, type, title, message, email_sent)
  VALUES (_uid, 'new_follower', 'J3a probe on', 'probe', true) RETURNING id INTO _nid;
  SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _url;
  SELECT id INTO _jid FROM public.jobs WHERE kind = 'push.send' AND idempotency_key = 'notification:' || _nid;
  IF _q1 <> _q0 THEN _fail := _fail || format('P3 switch ON: %s direct request(s), want 0', _q1 - _q0); END IF;
  IF _jid IS NULL THEN _fail := _fail || 'P3 switch ON: no push.send job'::text; END IF;

  IF _jid IS NOT NULL THEN
    -- P4
    SELECT * INTO _j FROM public.jobs WHERE id = _jid;
    IF _j.payload->>'user_id' IS DISTINCT FROM _uid::text OR _j.payload ? 'x-internal-secret'
       OR _j.payload::text ~* '"(authorization|apikey|secret|token|password)"' THEN
      _fail := _fail || 'P4 payload wrong or carries a secret'::text;
    END IF;
    -- P5
    PERFORM public.job_tick();
    SELECT * INTO _j FROM public.jobs WHERE id = _jid;
    IF _j.status <> 'running' OR _j.net_request_id IS NULL THEN
      _fail := _fail || format('P5 job not sent: %s / %s', _j.status, coalesce(_j.last_error, '-'));
    ELSE
      SELECT headers INTO _h FROM net.http_request_queue WHERE id = _j.net_request_id;
      IF NOT EXISTS (SELECT 1 FROM net.http_request_queue q WHERE q.id = _j.net_request_id
                       AND q.url = _url AND q.timeout_milliseconds = 60000) THEN
        _fail := _fail || 'P5 request is not this lane''s send-push with a 60 s timeout'::text;
      END IF;
      IF _h IS NULL OR NOT (_h ? 'x-internal-secret') OR coalesce(_h->>'x-internal-secret', '') = '' THEN
        _fail := _fail || 'P5 request lacks the x-internal-secret header'::text;
      END IF;
    END IF;
  END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'J3a FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'J3a FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'J3a PASS (lane %) — switch OFF = today''s direct push; switch ON = one keyed job, no secret in it, sent to this lane''s send-push with 60 s and its vault header',
    current_setting('p32.lane', true);
END
$p$;

ROLLBACK;

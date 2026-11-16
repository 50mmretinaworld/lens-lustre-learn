-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261116_1000 — J3c scheduled edge calls on the engine.
-- One transaction, ROLLBACK: pg_net sends queued requests only after COMMIT,
-- so nothing here ever reaches an edge function.
-- Before 20261116_1000: FAIL (cron_run missing). After: J3c PASS.
--   C1  every moved cron job: same schedule, command = cron_run('<job>'),
--       a cron.<job> kind (edge handler, 150 s, max 1 running, the agreed tries)
--       and its jobs:edge:<function> header copy — same headers as the old target
--   C2  cron_run / switch: members and visitors cannot call cron_run
--   C3  switch OFF → exactly today's call (cron_http_call), no job
--   C4  switch ON  → one cron.<job> job, already RUNNING with its request; the
--       request is the old target's URL with the old target's headers, 150 s
--   C5  the same minute again → still one job, no second request
--   C6  judging-invariants-nightly is untouched (judging stopped)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;
DO $p$
DECLARE
  _fail text[] := '{}';
  r record; k record; _t jsonb; _h jsonb; _x jsonb; _j record;
  _want int[]; _moved int := 0; _q0 int; _q1 int; _id bigint; _id2 bigint; _probe text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'J3c lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.cron_run(text)') IS NULL THEN
    RAISE EXCEPTION 'J3c FAIL: cron_run missing — expected before 20261116_1000';
  END IF;

  -- C1
  FOR r IN SELECT * FROM (VALUES
      ('apply-scheduled-boosts', 1), ('autoscale-ad-traffic', 2), ('expire-gift-credits', 3),
      ('backup-reminder', 3), ('send-reengagement-emails', 1)) v(job, tries)
  LOOP
    SELECT decrypted_secret::jsonb INTO _t FROM vault.decrypted_secrets WHERE name = 'p9_cron_http:' || r.job;
    CONTINUE WHEN _t IS NULL OR NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = r.job);
    _moved := _moved + 1;
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = r.job AND command = format('SELECT public.cron_run(%L);', r.job)) THEN
      _fail := _fail || format('C1 %s: cron command is not cron_run', r.job);
    END IF;
    SELECT * INTO k FROM public.job_kinds WHERE kind = 'cron.' || r.job;
    IF k.kind IS NULL THEN
      _fail := _fail || format('C1 %s: no job kind', r.job);
      CONTINUE;
    END IF;
    IF k.handler <> 'edge:' || substring(_t->>'url' FROM '/functions/v1/([A-Za-z0-9_-]+)$')
       OR k.timeout_seconds <> 150 OR k.max_running <> 1 OR k.max_attempts <> r.tries OR NOT k.enabled THEN
      _fail := _fail || format('C1 %s: kind %s / %s s / run %s / tries %s', r.job, k.handler, k.timeout_seconds, k.max_running, k.max_attempts);
    END IF;
    SELECT decrypted_secret::jsonb INTO _h FROM vault.decrypted_secrets WHERE name = k.extra_headers_secret;
    IF _h IS NULL OR _h <> coalesce(_t->'headers', '{}'::jsonb) THEN
      _fail := _fail || format('C1 %s: header copy missing or different from the old target', r.job);
    END IF;
  END LOOP;
  RAISE NOTICE 'J3c moved jobs on this lane: %', _moved;
  IF _moved = 0 THEN _fail := _fail || 'C1 no cron job was moved on this lane'::text; END IF;

  -- C2
  IF has_function_privilege('authenticated', 'public.cron_run(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cron_run(text)', 'EXECUTE') THEN
    _fail := _fail || 'C2 members or visitors can call cron_run'::text;
  END IF;

  -- pick the first moved job for the behaviour checks
  SELECT replace(kind, 'cron.', '') INTO _probe FROM public.job_kinds WHERE kind LIKE 'cron.%' ORDER BY kind LIMIT 1;
  IF _probe IS NOT NULL THEN
    SELECT decrypted_secret::jsonb INTO _t FROM vault.decrypted_secrets WHERE name = 'p9_cron_http:' || _probe;
    -- C3
    UPDATE public.system_flags SET value = true WHERE key = 'job_engine';
    UPDATE public.system_flags SET value = false WHERE key = 'job_engine_cron_http';
    SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _t->>'url';
    PERFORM public.cron_run(_probe);
    SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _t->>'url';
    IF _q1 - _q0 <> 1 THEN _fail := _fail || format('C3 switch OFF: %s request(s), want 1', _q1 - _q0); END IF;
    IF EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'cron.' || _probe) THEN _fail := _fail || 'C3 job made with switch OFF'::text; END IF;
    -- C4
    UPDATE public.system_flags SET value = true WHERE key = 'job_engine_cron_http';
    SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _t->>'url';
    _id := public.cron_run(_probe);
    SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _t->>'url';
    SELECT * INTO _j FROM public.jobs WHERE id = _id;
    IF _j.id IS NULL OR _j.kind <> 'cron.' || _probe THEN
      _fail := _fail || 'C4 no cron job in the book'::text;
    ELSE
      IF _j.status <> 'running' OR _j.net_request_id IS NULL OR _j.attempts <> 1 THEN
        _fail := _fail || format('C4 not started at once: %s, request %s', _j.status, coalesce(_j.net_request_id::text, '-'));
      END IF;
      IF _q1 - _q0 <> 1 THEN _fail := _fail || format('C4 %s request(s), want 1', _q1 - _q0); END IF;
      SELECT headers INTO _x FROM net.http_request_queue WHERE id = _j.net_request_id;
      IF NOT EXISTS (SELECT 1 FROM net.http_request_queue q WHERE q.id = _j.net_request_id
                      AND q.url = _t->>'url' AND q.timeout_milliseconds = 150000) THEN
        _fail := _fail || 'C4 request is not the old URL with 150 s'::text;
      END IF;
      IF _x IS NULL OR NOT (_x @> coalesce(_t->'headers', '{}'::jsonb)) THEN
        _fail := _fail || 'C4 request does not carry the old target''s headers'::text;
      END IF;
      IF _j.payload <> '{}'::jsonb THEN _fail := _fail || 'C4 payload is not empty'::text; END IF;
      -- C5
      SELECT count(*) INTO _q0 FROM net.http_request_queue WHERE url = _t->>'url';
      _id2 := public.cron_run(_probe);
      SELECT count(*) INTO _q1 FROM net.http_request_queue WHERE url = _t->>'url';
      IF _id2 <> _id OR _q1 <> _q0 OR (SELECT count(*) FROM public.jobs WHERE kind = 'cron.' || _probe) <> 1 THEN
        _fail := _fail || 'C5 the same minute made a second job or request'::text;
      END IF;
    END IF;
  END IF;

  -- C6
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'judging-invariants-nightly' AND command ~ 'cron_run')
     OR EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'cron.judging-invariants-nightly') THEN
    _fail := _fail || 'C6 judging-invariants-nightly was moved'::text;
  END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _probe IN ARRAY _fail LOOP RAISE NOTICE 'J3c FAIL item: %', _probe; END LOOP;
    RAISE EXCEPTION 'J3c FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'J3c PASS (lane %) — % job(s): cron → cron_run, same URL + headers, 150 s, one job per minute, switch OFF = today''s call',
    current_setting('p32.lane', true), _moved;
END
$p$;
ROLLBACK;

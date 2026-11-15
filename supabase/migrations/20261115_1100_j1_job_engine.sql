-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1100 · J1 + J2 — one job engine ("one manager, one record book")
-- Owner "go" 15 Nov 2026 (plan: Job Engine and Messages Work Plan, Part 1).
--
-- Measured first by PROBE J0 (staging run 43698701455, production run
-- 43700457699): 34 cron jobs on live all "succeeded" for 7 days while 8 HTTP
-- calls timed out and 252 pushes sat in 'sending' for up to 5 days — a cron
-- run counts as success when it STARTS a call, not when the work is done.
--
-- This file builds the engine with its switch OFF (system_flags.job_engine =
-- false). Nothing existing is moved here; groups move in J3, one switch each.
--   jobs        — the record book: one row per piece of work, never run twice
--                 (unique kind + idempotency_key), status queued → running →
--                 done | failed. Retries after 1, 5, 30 min, then 'failed'.
--   job_kinds   — the registry: handler ('sql:public.fn' taking jsonb, or
--                 'edge:function-name'), attempts, backoff, timeout, max running.
--   job_enqueue — the only way in (service role only). Refuses payloads that
--                 carry secrets.
--   job_tick    — every minute: settles edge calls from their real HTTP result
--                 (2xx = done; error, non-2xx or no answer by the lease = retry),
--                 frees stuck jobs, claims due work (SKIP LOCKED, per-kind
--                 limit), runs it, raises/clears alarms (J2), trims old rows.
--   job_requeue — run a failed job again (service role; admin page in J5).
-- Members and signed-out visitors have no access to any of it.
--
-- Rollback: supabase/rollback/20261115_1100_j1_job_engine_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261115_1100_j1_job_engine.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('cron.schedule(text,text,text)') IS NULL OR to_regclass('net._http_response') IS NULL
     OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE EXCEPTION 'J1-PRE-001: pg_cron, pg_net and vault must be installed on this lane';
  END IF;
  IF to_regclass('public.jobs') IS NOT NULL OR to_regclass('public.job_kinds') IS NOT NULL THEN
    RAISE EXCEPTION 'J1-PRE-002: public.jobs / public.job_kinds already exist — not re-applying';
  END IF;
END
$lane_guard$;

-- ── 1. the switch (OFF) ────────────────────────────────────────────────────
INSERT INTO public.system_flags (key, value) VALUES ('job_engine', false)
ON CONFLICT (key) DO NOTHING;

-- ── 2. registry ────────────────────────────────────────────────────────────
CREATE TABLE public.job_kinds (
  kind            text PRIMARY KEY CHECK (kind ~ '^[a-z][a-z0-9_.-]{1,62}$'),
  handler         text NOT NULL CHECK (handler ~ '^(sql:public\.[a-z_][a-z0-9_]{0,62}|edge:[a-z0-9][a-z0-9_-]{0,62})$'),
  max_attempts    integer NOT NULL DEFAULT 4 CHECK (max_attempts BETWEEN 1 AND 20),
  backoff_seconds integer[] NOT NULL DEFAULT ARRAY[60, 300, 1800],
  timeout_seconds integer NOT NULL DEFAULT 60 CHECK (timeout_seconds BETWEEN 5 AND 900),
  max_running     integer NOT NULL DEFAULT 5 CHECK (max_running BETWEEN 1 AND 100),
  enabled         boolean NOT NULL DEFAULT true,
  note            text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- ── 3. record book ─────────────────────────────────────────────────────────
CREATE TABLE public.jobs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind            text NOT NULL REFERENCES public.job_kinds (kind),
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text,
  status          text NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued', 'running', 'done', 'failed', 'cancelled')),
  run_at          timestamptz NOT NULL DEFAULT now(),
  attempts        integer NOT NULL DEFAULT 0,
  lease_until     timestamptz,
  net_request_id  bigint,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  started_at      timestamptz,
  finished_at     timestamptz,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX jobs_kind_key_uq ON public.jobs (kind, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX jobs_due_idx      ON public.jobs (run_at) WHERE status = 'queued';
CREATE INDEX jobs_running_idx  ON public.jobs (kind, lease_until) WHERE status = 'running';
CREATE INDEX jobs_finished_idx ON public.jobs (finished_at) WHERE status IN ('done', 'failed', 'cancelled');

ALTER TABLE public.job_kinds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs      ENABLE ROW LEVEL SECURITY;
-- no policies: members and signed-out visitors see and change nothing.
REVOKE ALL ON public.job_kinds FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.jobs      FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.job_kinds TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.jobs      TO service_role;

-- ── 4. internal: one failed attempt → retry later, or the failed list ──────
CREATE FUNCTION public.job_fail_attempt(_id bigint, _error text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  j public.jobs;
  k public.job_kinds;
  _wait integer;
  _msg text := left(regexp_replace(coalesce(_error, 'unknown error'), '[A-Za-z0-9_\-\.=+/]{20,}', '***', 'g'), 500);
BEGIN
  SELECT * INTO j FROM public.jobs WHERE id = _id FOR UPDATE;
  IF NOT FOUND OR j.status <> 'running' THEN RETURN 'skipped'; END IF;
  SELECT * INTO k FROM public.job_kinds WHERE kind = j.kind;
  IF j.attempts >= k.max_attempts THEN
    UPDATE public.jobs SET status = 'failed', last_error = _msg, lease_until = NULL, net_request_id = NULL,
                           finished_at = now(), updated_at = now()
     WHERE id = _id;
    RETURN 'failed';
  END IF;
  _wait := k.backoff_seconds[least(j.attempts, cardinality(k.backoff_seconds))];
  UPDATE public.jobs SET status = 'queued', last_error = _msg, lease_until = NULL, net_request_id = NULL,
                         run_at = now() + make_interval(secs => coalesce(_wait, 60)), updated_at = now()
   WHERE id = _id;
  RETURN 'retry';
END
$fn$;

-- ── 5. the only way in ─────────────────────────────────────────────────────
CREATE FUNCTION public.job_enqueue(_kind text, _payload jsonb DEFAULT '{}'::jsonb,
                                   _idempotency_key text DEFAULT NULL, _run_at timestamptz DEFAULT now())
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _id bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = _kind AND enabled) THEN
    RAISE EXCEPTION 'job_enqueue: unknown or disabled job kind %', coalesce(_kind, '<null>') USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _payload IS NULL OR jsonb_typeof(_payload) <> 'object' OR pg_column_size(_payload) > 65536 THEN
    RAISE EXCEPTION 'job_enqueue: payload must be a JSON object under 64 KB' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _payload::text ~* '"(authorization|apikey|api_key|password|secret|service_role|token|access_token|refresh_token)"\s*:' THEN
    RAISE EXCEPTION 'job_enqueue: payload must not carry keys or passwords (keep them in the vault)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  INSERT INTO public.jobs (kind, payload, idempotency_key, run_at)
  VALUES (_kind, _payload, _idempotency_key, coalesce(_run_at, now()))
  ON CONFLICT (kind, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
  RETURNING id INTO _id;
  IF _id IS NULL THEN
    SELECT id INTO _id FROM public.jobs WHERE kind = _kind AND idempotency_key = _idempotency_key;
  END IF;
  RETURN _id;
END
$fn$;

-- ── 6. run a failed (or cancelled) job again ───────────────────────────────
CREATE FUNCTION public.job_requeue(_id bigint)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.jobs SET status = 'queued', attempts = 0, run_at = now(), lease_until = NULL,
                         net_request_id = NULL, finished_at = NULL, updated_at = now()
   WHERE id = _id AND status IN ('failed', 'cancelled');
  RETURN FOUND;
END
$fn$;

-- ── 7. the manager: one tick a minute ──────────────────────────────────────
CREATE FUNCTION public.job_tick()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  r record;
  k record;
  j public.jobs;
  _on boolean;
  _edge jsonb;
  _proc regprocedure;
  _req bigint;
  _slots integer;
  _budget integer := 50;
  _done integer := 0; _retry integer := 0; _failed integer := 0; _started integer := 0;
  _res text;
  _bad integer; _late integer;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('public.job_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tick is running');
  END IF;
  SELECT value INTO _on FROM public.system_flags WHERE key = 'job_engine';

  IF coalesce(_on, false) THEN
    -- (a) settle edge calls from their real HTTP result
    FOR r IN
      SELECT jb.id, resp.status_code, resp.timed_out, resp.error_msg, (resp.id IS NOT NULL) AS answered, jb.lease_until
        FROM public.jobs jb
        LEFT JOIN net._http_response resp ON resp.id = jb.net_request_id
       WHERE jb.status = 'running' AND jb.net_request_id IS NOT NULL
       FOR UPDATE OF jb SKIP LOCKED
    LOOP
      IF r.answered AND r.status_code BETWEEN 200 AND 299 THEN
        UPDATE public.jobs SET status = 'done', lease_until = NULL, finished_at = now(), updated_at = now(),
                               last_error = NULL WHERE id = r.id;
        _done := _done + 1;
      ELSIF r.answered THEN
        _res := public.job_fail_attempt(r.id, CASE WHEN r.timed_out THEN 'timed out'
                                                   WHEN r.error_msg IS NOT NULL THEN r.error_msg
                                                   ELSE 'HTTP ' || coalesce(r.status_code::text, '?') END);
        IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
      ELSIF r.lease_until < now() THEN
        _res := public.job_fail_attempt(r.id, 'no answer before the lease ran out');
        IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
      END IF;
    END LOOP;

    -- (b) free stuck work (a run that died without settling)
    FOR r IN
      SELECT id FROM public.jobs
       WHERE status = 'running' AND net_request_id IS NULL AND lease_until < now()
       FOR UPDATE SKIP LOCKED
    LOOP
      _res := public.job_fail_attempt(r.id, 'stuck: lease ran out');
      IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
    END LOOP;

    -- (c) claim and run due work, per kind within its limit
    SELECT decrypted_secret::jsonb INTO _edge FROM vault.decrypted_secrets WHERE name = 'jobs:edge';
    FOR k IN
      SELECT jk.*, (SELECT count(*) FROM public.jobs x WHERE x.kind = jk.kind AND x.status = 'running') AS running_now
        FROM public.job_kinds jk
       WHERE jk.enabled
         AND EXISTS (SELECT 1 FROM public.jobs q WHERE q.kind = jk.kind AND q.status = 'queued' AND q.run_at <= now())
       ORDER BY jk.kind
    LOOP
      _slots := least(k.max_running - k.running_now, _budget);
      CONTINUE WHEN _slots <= 0;
      FOR j IN
        SELECT * FROM public.jobs
         WHERE kind = k.kind AND status = 'queued' AND run_at <= now()
         ORDER BY run_at, id
         LIMIT _slots
         FOR UPDATE SKIP LOCKED
      LOOP
        _budget := _budget - 1;
        UPDATE public.jobs SET status = 'running', attempts = attempts + 1, started_at = now(),
                               lease_until = now() + make_interval(secs => k.timeout_seconds), updated_at = now()
         WHERE id = j.id;
        _started := _started + 1;
        IF k.handler LIKE 'sql:%' THEN
          BEGIN
            _proc := to_regprocedure(substr(k.handler, 5) || '(jsonb)');
            IF _proc IS NULL THEN
              RAISE EXCEPTION 'handler % (jsonb) does not exist', substr(k.handler, 5);
            END IF;
            -- handler text is pinned by the job_kinds CHECK to public.<lowercase identifier>
            EXECUTE format('SELECT %s($1)', substr(k.handler, 5)) USING j.payload;
            UPDATE public.jobs SET status = 'done', lease_until = NULL, finished_at = now(), updated_at = now(),
                                   last_error = NULL WHERE id = j.id;
            _done := _done + 1;
          EXCEPTION WHEN OTHERS THEN
            _res := public.job_fail_attempt(j.id, SQLSTATE || ' ' || SQLERRM);
            IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
          END;
        ELSE
          IF _edge IS NULL OR _edge->>'base_url' IS NULL THEN
            _res := public.job_fail_attempt(j.id, 'no vault target jobs:edge on this lane');
            IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
          ELSE
            _req := net.http_post(
              url := (_edge->>'base_url') || '/functions/v1/' || substr(k.handler, 6),
              body := j.payload || jsonb_build_object('job_id', j.id, 'attempt', j.attempts + 1),
              params := '{}'::jsonb,
              headers := coalesce(_edge->'headers', '{"Content-Type": "application/json"}'::jsonb),
              timeout_milliseconds := k.timeout_seconds * 1000);
            UPDATE public.jobs SET net_request_id = _req WHERE id = j.id;
          END IF;
        END IF;
        EXIT WHEN _budget <= 0;
      END LOOP;
      EXIT WHEN _budget <= 0;
    END LOOP;
  END IF;

  -- (d) J2 alarms — evaluated even with the switch off, so leftovers are seen
  SELECT count(*) INTO _bad FROM public.jobs WHERE status = 'failed' AND finished_at > now() - interval '24 hours';
  SELECT count(*) INTO _late FROM public.jobs WHERE status = 'queued' AND run_at < now() - interval '10 minutes'
                                                   AND attempts = 0;
  PERFORM public.ops_alarm_set('jobs:failed', _bad > 0,
    format('%s background job(s) failed in the last 24 hours', _bad), jsonb_build_object('failed_24h', _bad));
  PERFORM public.ops_alarm_set('jobs:overdue', coalesce(_on, false) AND _late > 0,
    format('%s background job(s) waiting more than 10 minutes', _late), jsonb_build_object('overdue', _late));

  -- (e) trim the book
  DELETE FROM public.jobs WHERE status = 'done' AND finished_at < now() - interval '14 days';
  DELETE FROM public.jobs WHERE status IN ('failed', 'cancelled') AND finished_at < now() - interval '90 days';

  RETURN jsonb_build_object('on', coalesce(_on, false), 'started', _started, 'done', _done,
                            'retry', _retry, 'failed', _failed, 'failed_24h', _bad, 'overdue', _late);
END
$fn$;

REVOKE ALL ON FUNCTION public.job_fail_attempt(bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.job_enqueue(text, jsonb, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.job_requeue(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.job_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.job_enqueue(text, jsonb, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.job_requeue(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.job_tick() TO service_role;

-- ── 8. edge target in the vault (copied from an existing cron target) ──────
DO $edge$
DECLARE
  _src jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'jobs:edge') THEN
    RETURN;
  END IF;
  SELECT decrypted_secret::jsonb INTO _src FROM vault.decrypted_secrets
   WHERE name LIKE 'p9_cron_http:%' AND decrypted_secret::jsonb->>'url' ~ '^https://[^/]+/functions/v1/'
   ORDER BY name LIMIT 1;
  IF _src IS NULL THEN
    RAISE EXCEPTION 'J1-EDGE-001: no p9_cron_http:* vault target to copy the edge base URL and headers from';
  END IF;
  PERFORM vault.create_secret(
    jsonb_build_object('base_url', substring(_src->>'url' FROM '^(https://[^/]+)'),
                       'headers', coalesce(_src->'headers', '{}'::jsonb))::text,
    'jobs:edge', 'J1 · 20261115_1100 · base URL + headers the job engine uses to call edge functions');
END
$edge$;

-- ── 9. the minute tick (does nothing but alarms while the switch is OFF) ───
SELECT cron.schedule('job-engine-tick', '* * * * *', $cron$SELECT public.job_tick();$cron$);

COMMIT;

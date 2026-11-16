-- ═══════════════════════════════════════════════════════════════════════════
-- 20261116_1000 · J3c — the five scheduled edge calls go through the job engine
-- (J3 group 2; Owner "go" 15 Nov 2026, Job Engine plan Part 1)
--
-- Measured by J0 (production run 43700457699): these cron jobs call an edge
-- function through public.cron_http_call and count as "succeeded" the moment
-- the call STARTS — a timeout, a 500 or a wrong secret is never seen. J0 found
-- 8 pg_net timeouts (cron_http_call's 5 s default) on live.
--
-- With J3c (switch job_engine_cron_http ON):
--   cron keeps the SAME schedule but runs public.cron_run('<job>'), which puts
--   one job in the book (one per job per minute — never twice) and starts it at
--   once (job_start). The tick settles it from the REAL HTTP answer; a failure
--   is retried (where safe) and raises the jobs:failed alarm.
--   Switch OFF (the default here) = cron_run calls cron_http_call exactly as today.
--
-- Same call as today: same edge function, same headers (copied from the job's
-- own vault target p9_cron_http:<job> into jobs:edge:<function>). The functions
-- do not read the request body, so the job payload is {} — no secret is stored
-- in the job book. Timeout 150 s (edge wall-clock limit) instead of 5 s, so a
-- slow but successful run is no longer a false timeout.
--
-- Retries — never send anything twice:
--   apply-scheduled-boosts    */5     1 try  (a retry could add boost likes twice;
--                                            the next run 5 min later picks it up)
--   autoscale-ad-traffic      6-hourly 2 tries (reads stats, sets levels)
--   expire-gift-credits       daily   3 tries (one ledger entry per credit)
--   backup-reminder           weekly  3 tries (function skips an unread duplicate)
--   send-reengagement-emails  daily   1 try  (never e-mail a member twice)
-- judging-invariants-nightly is NOT moved: judging work is stopped (Owner).
--
-- A job with no vault target on this lane is skipped (notice), as 20261005_0003 did.
-- Rollback: supabase/rollback/20261116_1000_j3c_cron_http_on_engine_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261116_1000_j3c_cron_http_on_engine.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

DO $pre$
BEGIN
  IF to_regprocedure('public.job_start(bigint)') IS NULL THEN
    RAISE EXCEPTION 'J3c-PRE-001: 20261115_1230 (J3b job_start) is not applied on this lane';
  END IF;
  IF to_regprocedure('public.cron_http_call(text)') IS NULL THEN
    RAISE EXCEPTION 'J3c-PRE-002: public.cron_http_call (20261005_0003) is missing on this lane';
  END IF;
  IF to_regprocedure('public.cron_run(text)') IS NOT NULL OR EXISTS (SELECT 1 FROM public.job_kinds WHERE kind LIKE 'cron.%') THEN
    RAISE EXCEPTION 'J3c-PRE-003: cron_run / cron.* job kinds already exist — not re-applying';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'jobs:edge') THEN
    RAISE EXCEPTION 'J3c-PRE-004: vault target jobs:edge (J1) is missing on this lane';
  END IF;
END
$pre$;

-- ── 1. the switch (OFF) ────────────────────────────────────────────────────
INSERT INTO public.system_flags (key, value) VALUES ('job_engine_cron_http', false)
ON CONFLICT (key) DO NOTHING;

-- ── 2. the one entry point cron calls ─────────────────────────────────────
CREATE FUNCTION public.cron_run(_job text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _on boolean;
  _id bigint;
BEGIN
  IF _job IS NULL OR _job !~ '^[a-z0-9][a-z0-9-]{0,62}$' THEN
    RAISE EXCEPTION 'cron_run: % is not a job name', coalesce(_job, '<null>') USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT bool_and(value) INTO _on FROM public.system_flags WHERE key IN ('job_engine', 'job_engine_cron_http');
  IF coalesce(_on, false)
     AND (SELECT count(*) FROM public.system_flags WHERE key IN ('job_engine', 'job_engine_cron_http')) = 2
     AND EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'cron.' || _job AND enabled) THEN
    _id := public.job_enqueue('cron.' || _job, '{}'::jsonb,
                              _job || ':' || to_char(date_trunc('minute', now() AT TIME ZONE 'UTC'), 'YYYYMMDD"T"HH24MI'));
    PERFORM public.job_start(_id);
    RETURN _id;
  END IF;
  RETURN public.cron_http_call(_job);   -- switch OFF: exactly today's call
END
$fn$;
REVOKE ALL ON FUNCTION public.cron_run(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cron_run(text) TO service_role;

-- ── 3. one job kind + header copy per function, then the cron command ─────
DO $move$
DECLARE
  _base text;
  _t jsonb;
  _fn text;
  _sched text;
  r record;
  _n int := 0;
BEGIN
  SELECT decrypted_secret::jsonb->>'base_url' INTO _base FROM vault.decrypted_secrets WHERE name = 'jobs:edge';
  FOR r IN
    SELECT * FROM (VALUES
      ('apply-scheduled-boosts',   1, ARRAY[60]),
      ('autoscale-ad-traffic',     2, ARRAY[300]),
      ('expire-gift-credits',      3, ARRAY[300, 1800]),
      ('backup-reminder',          3, ARRAY[300, 1800]),
      ('send-reengagement-emails', 1, ARRAY[60])
    ) AS v(job, attempts, backoff)
  LOOP
    SELECT decrypted_secret::jsonb INTO _t FROM vault.decrypted_secrets WHERE name = 'p9_cron_http:' || r.job;
    SELECT schedule INTO _sched FROM cron.job WHERE jobname = r.job;
    IF _t IS NULL OR _sched IS NULL THEN
      RAISE NOTICE 'J3c: % has no vault target or no cron job on this lane — skipped', r.job;
      CONTINUE;
    END IF;
    _fn := substring(_t->>'url' FROM '/functions/v1/([A-Za-z0-9_-]+)$');
    IF _fn IS NULL OR _t->>'url' <> _base || '/functions/v1/' || _fn THEN
      RAISE EXCEPTION 'J3c-MOVE-001: % does not call an edge function of this lane''s jobs:edge base', r.job;
    END IF;
    IF _fn !~ '^[a-z0-9-]{1,40}$' THEN
      RAISE EXCEPTION 'J3c-MOVE-002: function name % does not fit a jobs:edge:<name> secret', _fn;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_each(coalesce(_t->'headers', '{}'::jsonb)) h WHERE h.value = 'null'::jsonb) THEN
      RAISE EXCEPTION 'J3c-MOVE-003: a header of % is NULL on this lane', r.job;
    END IF;
    IF EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'jobs:edge:' || _fn) THEN
      RAISE EXCEPTION 'J3c-MOVE-004: vault secret jobs:edge:% already exists', _fn;
    END IF;
    PERFORM vault.create_secret(coalesce(_t->'headers', '{}'::jsonb)::text, 'jobs:edge:' || _fn,
            'J3c · 20261116_1000 · headers cron job ' || r.job || ' sends (copy of p9_cron_http:' || r.job || ')');
    INSERT INTO public.job_kinds (kind, handler, max_attempts, backoff_seconds, timeout_seconds, max_running,
                                  extra_headers_secret, note)
    VALUES ('cron.' || r.job, 'edge:' || _fn, r.attempts, r.backoff, 150, 1, 'jobs:edge:' || _fn,
            format('J3c: cron %s (%s) through the engine; %s tr%s', r.job, _sched, r.attempts,
                   CASE WHEN r.attempts = 1 THEN 'y' ELSE 'ies' END));
    PERFORM cron.schedule(r.job, _sched, format('SELECT public.cron_run(%L);', r.job));
    _n := _n + 1;
  END LOOP;
  RAISE NOTICE 'J3c: % cron job(s) now run through cron_run (switch job_engine_cron_http = OFF)', _n;
END
$move$;

COMMIT;

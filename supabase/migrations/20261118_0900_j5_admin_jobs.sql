-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_0900 · J5a — admin Job Engine page, READ ONLY (Job Engine plan Part 1 · J5)
--
-- Two admin-only read functions for /admin/jobs. No write, no retry button yet
-- (a retry can send a push or an e-mail twice — that is a separate unit with
-- its own Owner decision).
--   admin_jobs_overview() → jsonb
--     switches  job_engine / job_engine_push / job_engine_cron_http
--     kinds[]   per job kind: handler, enabled, limits, running, queued, due,
--               24 h done / failed / average seconds to done, last done,
--               last failed + its error (cut to 200 characters)
--     alarms[]  open ops_alarms whose key starts with 'jobs:'
--   admin_jobs_list(_status, _kind, _limit, _before_id) → rows
--     id, kind, status, attempts, max_attempts, run_at, created_at, started_at,
--     finished_at, last_error — NEVER the payload (it holds member ids and
--     notification text) and never the idempotency key.
-- Both: SECURITY DEFINER, search_path '', refuse anyone who is not an admin.
-- Rollback: supabase/rollback/20261118_0900_j5_admin_jobs_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_0900_j5_admin_jobs.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.jobs') IS NULL OR to_regclass('public.job_kinds') IS NULL THEN
    RAISE EXCEPTION 'J5-PRE-001: the job engine (20261115_1100) is not applied on this lane';
  END IF;
  IF to_regclass('public.ops_alarms') IS NULL THEN
    RAISE EXCEPTION 'J5-PRE-002: ops_alarms (20261103_0300) is missing on this lane';
  END IF;
  IF to_regprocedure('public.admin_jobs_overview()') IS NOT NULL THEN
    RAISE EXCEPTION 'J5-PRE-003: admin_jobs_overview already exists — not re-applying';
  END IF;
END
$lane_guard$;

CREATE FUNCTION public.admin_jobs_overview()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN jsonb_build_object(
    'checked_at', now(),
    'switches', (SELECT coalesce(jsonb_object_agg(f.key, f.value), '{}'::jsonb)
                   FROM public.system_flags f
                  WHERE f.key IN ('job_engine', 'job_engine_push', 'job_engine_cron_http')),
    'kinds', (
      SELECT coalesce(jsonb_agg(x ORDER BY x->>'kind'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object(
          'kind', k.kind,
          'handler', k.handler,
          'enabled', k.enabled,
          'max_running', k.max_running,
          'max_attempts', k.max_attempts,
          'timeout_seconds', k.timeout_seconds,
          'running', (SELECT count(*) FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'running'),
          'queued', (SELECT count(*) FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'queued'),
          'due', (SELECT count(*) FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'queued' AND j.run_at <= now()),
          'done_24h', (SELECT count(*) FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'done'
                                                          AND j.finished_at >= now() - interval '24 hours'),
          'failed_24h', (SELECT count(*) FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'failed'
                                                            AND j.finished_at >= now() - interval '24 hours'),
          'avg_seconds_24h', (SELECT round(avg(extract(epoch FROM j.finished_at - j.created_at))::numeric, 1)
                                FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'done'
                                                     AND j.finished_at >= now() - interval '24 hours'),
          'last_done_at', (SELECT max(j.finished_at) FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'done'),
          'last_failed_at', (SELECT max(j.finished_at) FROM public.jobs j WHERE j.kind = k.kind AND j.status = 'failed'),
          'last_error', (SELECT left(j.last_error, 200) FROM public.jobs j
                          WHERE j.kind = k.kind AND j.status = 'failed'
                          ORDER BY j.finished_at DESC NULLS LAST, j.id DESC LIMIT 1)
        ) AS x
        FROM public.job_kinds k
      ) s),
    'alarms', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('alarm_key', a.alarm_key, 'summary', a.summary,
                                                   'opened_at', a.opened_at, 'last_seen_at', a.last_seen_at)
                                ORDER BY a.opened_at DESC), '[]'::jsonb)
        FROM public.ops_alarms a
       WHERE a.closed_at IS NULL AND a.alarm_key LIKE 'jobs:%'));
END
$fn$;

CREATE FUNCTION public.admin_jobs_list(_status text DEFAULT NULL, _kind text DEFAULT NULL,
                                       _limit integer DEFAULT 50, _before_id bigint DEFAULT NULL)
RETURNS TABLE (id bigint, kind text, status text, attempts integer, max_attempts integer,
               run_at timestamptz, created_at timestamptz, started_at timestamptz,
               finished_at timestamptz, last_error text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _status IS NOT NULL AND _status NOT IN ('queued', 'running', 'done', 'failed', 'cancelled') THEN
    RAISE EXCEPTION 'unknown status %', _status USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN QUERY
    SELECT j.id, j.kind, j.status, j.attempts, k.max_attempts, j.run_at, j.created_at, j.started_at,
           j.finished_at, left(j.last_error, 300)
      FROM public.jobs j
      JOIN public.job_kinds k ON k.kind = j.kind
     WHERE (_status IS NULL OR j.status = _status)
       AND (_kind IS NULL OR j.kind = _kind)
       AND (_before_id IS NULL OR j.id < _before_id)
     ORDER BY j.id DESC
     LIMIT greatest(1, least(coalesce(_limit, 50), 200));
END
$fn$;

REVOKE ALL ON FUNCTION public.admin_jobs_overview() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_jobs_list(text, text, integer, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_jobs_overview() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_jobs_list(text, text, integer, bigint) TO authenticated, service_role;

COMMIT;

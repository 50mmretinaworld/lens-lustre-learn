-- ═══════════════════════════════════════════════════════════════════════════
-- 20261123_4900 · N5 speed dashboard + alarm (Owner 23 Nov: "build like Meta",
-- "full work complete"). Lanes: staging, production.
--
-- The app (N5a, src/lib/screenTiming.ts) reports how long each main screen took
-- to show: client_telemetry timing rows `screen.<name>` (from the tap) and
-- `screen.<name>.cold` (first screen, from the app starting), per platform.
--
--   admin_screen_speed(_days)   ADMIN ONLY. Per day × screen × platform: count,
--                               typical (p50), p75 and slowest-5 % (p95) in ms.
--                               Admin → App health draws it.
--   n5_screen_speed_alarms()    INTERNAL, pg_cron hourly ('n5-screen-speed'):
--                               over the last 24 h, a screen × platform with at
--                               least 30 reports whose p95 is above 6 s, or whose
--                               p50 is above 2.5 s, opens an alarm through the
--                               existing ops_alarm_set (→ alarm-relay.yml → an
--                               ALARM issue e-mailed to the Owner); back under
--                               the line closes it. The thresholds live here
--                               only (ONE place).
-- Reads telemetry only (no member id is stored there). NOT RE-RUNNABLE (PRE-002).
-- Rollback: supabase/rollback/20261123_4900_n5_screen_speed_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261123_4900_n5_screen_speed.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION
      'APPLY REFUSED — p32.lane reads %. Dispatch apply-migration.yml (it sets p32.lane from target).',
      coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regclass('public.client_telemetry') IS NULL
     OR to_regclass('public.ops_alarms') IS NULL
     OR to_regprocedure('public.ops_alarm_set(text,boolean,text,jsonb)') IS NULL
     OR to_regprocedure('public.has_role(uuid,public.app_role)') IS NULL
     OR to_regprocedure('cron.schedule(text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'N5-4900-PRE-001: a table or function this file builds on is missing';
  END IF;
  IF to_regprocedure('public.admin_screen_speed(integer)') IS NOT NULL
     OR to_regprocedure('public.n5_screen_speed_alarms()') IS NOT NULL
     OR EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'n5-screen-speed') THEN
    RAISE EXCEPTION 'N5-4900-PRE-002: already applied — roll back first';
  END IF;
END
$pre$;

-- ── 1. the admin read ──────────────────────────────────────────────────────
CREATE FUNCTION public.admin_screen_speed(_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE
  _uid  uuid := (SELECT auth.uid());
  _d    integer := GREATEST(1, LEAST(coalesce(_days, 7), 30));
  _from timestamptz := date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - make_interval(days => _d - 1);
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'N5-001: only an admin can read screen speed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN jsonb_build_object(
    'generated_at', now(),
    'days', _d,
    'rows', coalesce((
      SELECT jsonb_agg(r ORDER BY r.day DESC, r.screen, r.cold, r.platform) FROM (
        SELECT (c.created_at AT TIME ZONE 'UTC')::date AS day,
               split_part(c.metric, '.', 2) AS screen,
               (c.metric LIKE '%.cold') AS cold,
               c.platform,
               count(*) AS n,
               round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p50,
               round(percentile_cont(0.75) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p75,
               round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p95
          FROM public.client_telemetry c
         WHERE c.kind = 'timing' AND c.metric LIKE 'screen.%' AND c.created_at >= _from
         GROUP BY 1, 2, 3, 4) r), '[]'::jsonb));
END;
$fn$;
COMMENT ON FUNCTION public.admin_screen_speed(integer) IS
  '20261123_4900 N5: admin only — per day × screen × platform, how long screens took to show (p50/p75/p95 ms) from client_telemetry screen.* timings.';
REVOKE ALL ON FUNCTION public.admin_screen_speed(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_screen_speed(integer) TO authenticated, service_role;

-- ── 2. the alarm (internal, hourly) ────────────────────────────────────────
CREATE FUNCTION public.n5_screen_speed_alarms()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE
  -- THE thresholds (one place). p95: the slowest 1 in 20 waits longer than this.
  _p95_ms  constant integer := 6000;
  _p50_ms  constant integer := 2500;
  _min_n   constant integer := 30;
  r        record;
  _firing  integer := 0;
BEGIN
  FOR r IN
    SELECT split_part(c.metric, '.', 2) AS screen, c.platform, count(*) AS n,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p50,
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY c.duration_ms))::integer AS p95
      FROM public.client_telemetry c
     WHERE c.kind = 'timing' AND c.metric LIKE 'screen.%' AND c.metric NOT LIKE '%.cold'
       AND c.created_at > now() - interval '24 hours'
     GROUP BY 1, 2
  LOOP
    IF r.n >= _min_n AND (r.p95 > _p95_ms OR r.p50 > _p50_ms) THEN
      PERFORM public.ops_alarm_set('screen-speed:' || r.screen || ':' || r.platform, true,
        format('Screen "%s" is slow on %s: typical %s ms, slowest 5 %% %s ms (last 24 h, %s opens)', r.screen, r.platform, r.p50, r.p95, r.n),
        jsonb_build_object('screen', r.screen, 'platform', r.platform, 'n', r.n, 'p50', r.p50, 'p95', r.p95,
                           'limit_p50', _p50_ms, 'limit_p95', _p95_ms));
      _firing := _firing + 1;
    ELSE
      PERFORM public.ops_alarm_set('screen-speed:' || r.screen || ':' || r.platform, false, NULL, NULL);
    END IF;
  END LOOP;
  RETURN _firing;
END;
$fn$;
COMMENT ON FUNCTION public.n5_screen_speed_alarms() IS
  '20261123_4900 N5: hourly (cron n5-screen-speed) — opens/closes ops alarm screen-speed:<screen>:<platform> when the last 24 h p95 > 6 s or p50 > 2.5 s (>= 30 opens).';
REVOKE ALL ON FUNCTION public.n5_screen_speed_alarms() FROM PUBLIC, anon, authenticated, service_role;

SELECT cron.schedule('n5-screen-speed', '17 * * * *', 'SELECT public.n5_screen_speed_alarms()');

DO $post$
DECLARE _bad text := '';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.admin_screen_speed(integer)'::regprocedure AND prosecdef AND proconfig = ARRAY['search_path=""'])
     OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.n5_screen_speed_alarms()'::regprocedure AND prosecdef AND proconfig = ARRAY['search_path=""']) THEN
    _bad := _bad || E'\n  a function is not SECURITY DEFINER with search_path ''''';
  END IF;
  IF has_function_privilege('anon', 'public.admin_screen_speed(integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.n5_screen_speed_alarms()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.n5_screen_speed_alarms()', 'EXECUTE') THEN
    _bad := _bad || E'\n  wrong EXECUTE grants';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'n5-screen-speed') THEN
    _bad := _bad || E'\n  cron job n5-screen-speed missing';
  END IF;
  IF _bad <> '' THEN RAISE EXCEPTION 'N5-4900-POST:%', _bad; END IF;
  RAISE NOTICE 'N5-4900: admin_screen_speed (admin read) + n5_screen_speed_alarms (hourly cron n5-screen-speed) created';
END
$post$;

COMMIT;

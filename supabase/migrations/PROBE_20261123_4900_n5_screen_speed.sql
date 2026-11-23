-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261123_4900 N5 speed dashboard + alarm. WRITES NOTHING: one
-- transaction ending in ROLLBACK. FAILS before apply.
--   S1  structure, grants, hourly job
--   S2  admin_screen_speed refuses a non-admin; an admin gets rows with the shape
--   S3  35 slow "probe" screen reports → the alarm OPENS; fast ones → it CLOSES
-- Prints counts only.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';

DO $p$
DECLARE
  _admin uuid;
  _plain uuid;
  _j     jsonb;
  _ok    boolean;
  _open  integer;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  -- S1
  IF to_regprocedure('public.admin_screen_speed(integer)') IS NULL OR to_regprocedure('public.n5_screen_speed_alarms()') IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL S1: 4900 not applied';
  END IF;
  IF position('public.n5_screen_speed_alarms()' IN (SELECT p.prosrc FROM pg_proc p WHERE p.oid = 'public.purge_client_telemetry(integer)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'PROBE FAIL S1: the hourly purge does not call the alarm';
  END IF;
  IF has_function_privilege('anon', 'public.admin_screen_speed(integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.n5_screen_speed_alarms()', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL S1: grants';
  END IF;

  -- S2
  -- role::text = '…' works whether user_roles.role is app_role (production) or text (staging).
  SELECT ur.user_id INTO _admin FROM public.user_roles ur WHERE ur.role::text = 'admin' LIMIT 1;
  SELECT p.id INTO _plain FROM public.profiles p
   WHERE NOT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p.id AND ur.role::text = 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _plain::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.admin_screen_speed(7);
    _ok := false;
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  RESET ROLE;
  IF NOT _ok THEN RAISE EXCEPTION 'PROBE FAIL S2: a plain member could read screen speed'; END IF;

  INSERT INTO public.client_telemetry (kind, metric, ok, duration_ms, platform, app_build, route)
  SELECT 'timing', 'screen.probe4900', true, 9000 + g, 'web', 'probe', NULL FROM generate_series(1, 35) g;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  _j := public.admin_screen_speed(7);
  RESET ROLE;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(_j->'rows') x
                  WHERE x->>'screen' = 'probe4900' AND (x->>'n')::int = 35 AND (x->>'p95')::int > 9000 AND x->>'platform' = 'web') THEN
    RAISE EXCEPTION 'PROBE FAIL S2: admin read did not return the probe row';
  END IF;

  -- S3
  PERFORM public.n5_screen_speed_alarms();
  SELECT count(*) INTO _open FROM public.ops_alarms WHERE alarm_key = 'screen-speed:probe4900:web' AND closed_at IS NULL;
  IF _open <> 1 THEN RAISE EXCEPTION 'PROBE FAIL S3: slow screen did not open the alarm (open %)', _open; END IF;
  DELETE FROM public.client_telemetry WHERE metric = 'screen.probe4900';
  INSERT INTO public.client_telemetry (kind, metric, ok, duration_ms, platform, app_build, route)
  SELECT 'timing', 'screen.probe4900', true, 300, 'web', 'probe', NULL FROM generate_series(1, 35) g;
  PERFORM public.n5_screen_speed_alarms();
  SELECT count(*) INTO _open FROM public.ops_alarms WHERE alarm_key = 'screen-speed:probe4900:web' AND closed_at IS NULL;
  IF _open <> 0 THEN RAISE EXCEPTION 'PROBE FAIL S3: fast screen did not close the alarm'; END IF;

  RAISE NOTICE 'N5-4900 PASS (lane %): S1–S3 hold; real screen rows in 7 days: %', current_setting('p32.lane'),
    (SELECT count(*) FROM public.client_telemetry WHERE metric LIKE 'screen.%' AND metric <> 'screen.probe4900' AND created_at > now() - interval '7 days');
END
$p$;

ROLLBACK;

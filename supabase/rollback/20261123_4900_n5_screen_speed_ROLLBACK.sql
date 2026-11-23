-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261123_4900 N5 speed dashboard + alarm. Lanes: staging, production.
-- Puts purge_client_telemetry back to the 20261028_0001 body (byte for byte —
-- POST checks its md5), closes any open screen-speed alarm, drops both N5
-- functions. Telemetry rows are untouched.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

-- 1. the purge back to its own body (before the function it calls is dropped)
CREATE OR REPLACE FUNCTION public.purge_client_telemetry(_batch integer DEFAULT 100000)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO ''
AS $fn$
DECLARE
  _b integer := GREATEST(1, LEAST(coalesce(_batch, 100000), 1000000));
  _t integer;
  _q integer;
BEGIN
  DELETE FROM public.client_telemetry
   WHERE id = ANY (ARRAY(SELECT id FROM public.client_telemetry
                          WHERE created_at < now() - interval '30 days' LIMIT _b));
  GET DIAGNOSTICS _t = ROW_COUNT;
  DELETE FROM public.client_telemetry_quota WHERE hour < now() - interval '2 hours';
  GET DIAGNOSTICS _q = ROW_COUNT;
  RETURN jsonb_build_object('client_telemetry', _t, 'client_telemetry_quota', _q);
END;
$fn$;

-- 2. alarms closed, functions gone
UPDATE public.ops_alarms SET closed_at = now(), last_seen_at = now()
 WHERE alarm_key LIKE 'screen-speed:%' AND closed_at IS NULL;
DROP FUNCTION IF EXISTS public.n5_screen_speed_alarms();
DROP FUNCTION IF EXISTS public.admin_screen_speed(integer);

DO $post$
BEGIN
  IF to_regprocedure('public.admin_screen_speed(integer)') IS NOT NULL
     OR to_regprocedure('public.n5_screen_speed_alarms()') IS NOT NULL
     OR (SELECT md5(p.prosrc) FROM pg_proc p WHERE p.oid = 'public.purge_client_telemetry(integer)'::regprocedure)
        IS DISTINCT FROM '950e1ab7a758991de6063ee173bdfc2d' THEN
    RAISE EXCEPTION 'N5-4900-RB-POST: not back to the pre-4900 state';
  END IF;
  RAISE NOTICE 'N5-4900 ROLLBACK: purge back to its 20261028_0001 body, screen-speed alarms closed, functions dropped';
END
$post$;

COMMIT;

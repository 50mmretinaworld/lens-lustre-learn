-- ═══════════════════════════════════════════════════════════════════════════
-- 20261123_5000 · N3: ONE request answers every feature switch for the caller.
-- (Owner 23 Nov: "build like Meta".) Lanes: staging, production.
--
-- The app asked feature_allowed_me(<one switch>) once per switch, every 60 s
-- (R-103) — 5 requests a minute on the feed. features_allowed_me() returns
-- { "<switch>": true|false, … } for EVERY row of feature_access, decided by the
-- same rule (public.feature_allowed) for the CALLER only (auth.uid()). It tells
-- a member nothing the per-switch call does not already tell them.
-- feature_allowed_me stays (installed apps use it). NOT RE-RUNNABLE (PRE-002).
-- Rollback: supabase/rollback/20261123_5000_features_allowed_me_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261123_5000_features_allowed_me.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regclass('public.feature_access') IS NULL OR to_regprocedure('public.feature_allowed(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'N3-5000-PRE-001: feature_access / feature_allowed missing';
  END IF;
  IF to_regprocedure('public.features_allowed_me()') IS NOT NULL THEN
    RAISE EXCEPTION 'N3-5000-PRE-002: already applied — roll back first';
  END IF;
END
$pre$;

CREATE FUNCTION public.features_allowed_me()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  SELECT coalesce(jsonb_object_agg(fa.feature, public.feature_allowed(fa.feature, (SELECT auth.uid()))), '{}'::jsonb)
    FROM public.feature_access fa;
$fn$;
COMMENT ON FUNCTION public.features_allowed_me() IS
  '20261123_5000 N3: every feature switch for the CALLER in one answer ({switch: bool}); same rule as feature_allowed_me. Signed out: every switch false.';
REVOKE ALL ON FUNCTION public.features_allowed_me() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.features_allowed_me() TO authenticated;

DO $post$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.features_allowed_me()'::regprocedure AND prosecdef AND proconfig = ARRAY['search_path=""'])
     OR has_function_privilege('anon', 'public.features_allowed_me()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.features_allowed_me()', 'EXECUTE') THEN
    RAISE EXCEPTION 'N3-5000-POST: features_allowed_me not as intended';
  END IF;
  RAISE NOTICE 'N3-5000: features_allowed_me created (definer, search_path '''', authenticated only)';
END
$post$;

COMMIT;

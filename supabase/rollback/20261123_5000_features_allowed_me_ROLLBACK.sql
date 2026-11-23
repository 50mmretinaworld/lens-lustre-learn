-- ROLLBACK · 20261123_5000 features_allowed_me. The app falls back to the per-switch call by itself.
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
DROP FUNCTION IF EXISTS public.features_allowed_me();
DO $post$
BEGIN
  IF to_regprocedure('public.features_allowed_me()') IS NOT NULL THEN RAISE EXCEPTION 'N3-5000-RB-POST: still there'; END IF;
  RAISE NOTICE 'N3-5000 ROLLBACK: features_allowed_me dropped';
END
$post$;
COMMIT;

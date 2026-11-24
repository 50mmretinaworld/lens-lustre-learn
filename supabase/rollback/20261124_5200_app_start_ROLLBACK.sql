-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261124_5200 get_app_start. Lanes: staging, production.
-- Drops the one start-up function. The app then asks each part alone, exactly as before 5200 (it treats a missing
-- function as "ask separately"). Nothing else changed in 5200.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED — p32.lane reads %. Dispatch apply-migration.yml (it sets p32.lane from target).',
      coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

REVOKE ALL ON FUNCTION public.get_app_start(integer, text[]) FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.get_app_start(integer, text[]);

DO $post$
BEGIN
  IF to_regprocedure('public.get_app_start(integer,text[])') IS NOT NULL THEN
    RAISE EXCEPTION 'N6-5200-ROLLBACK-POST: get_app_start still exists';
  END IF;
  RAISE NOTICE 'N6-5200 ROLLBACK: get_app_start dropped';
END
$post$;

COMMIT;

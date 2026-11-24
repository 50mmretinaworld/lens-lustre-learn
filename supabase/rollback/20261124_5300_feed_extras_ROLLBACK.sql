-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261124_5300 get_feed_extras. Lanes: staging, production.
-- Drops the one feed-extras function. The app then asks each part alone, exactly as before 5300 (it treats a
-- missing function as "ask separately"). Nothing else changed in 5300.
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

REVOKE ALL ON FUNCTION public.get_feed_extras(uuid[], uuid[], boolean) FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.get_feed_extras(uuid[], uuid[], boolean);

DO $post$
BEGIN
  IF to_regprocedure('public.get_feed_extras(uuid[],uuid[],boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'N6-5300-ROLLBACK-POST: get_feed_extras still exists';
  END IF;
  RAISE NOTICE 'N6-5300 ROLLBACK: get_feed_extras dropped';
END
$post$;

COMMIT;

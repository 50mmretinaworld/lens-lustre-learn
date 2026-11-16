-- ═══════════════════════════════════════════════════════════════════════════
-- 20261116_1500 · A1 fix — the account guard does not stop the converter account
--
-- What broke: production guard ON (20261116_0900, run 43859935121, 11:41 UTC).
-- One minute later the scheduled photo-blur worker was refused:
--   photo_blur_record 403 ACCOUNT_UNDER_REVIEW   (run 43860062887)
-- The media / video worker signs in as the converter account. 20261013_0007
-- marked that account's profile banned + hidden ON PURPOSE (so it never shows
-- as a member and cannot post), and account_can_act() counts every banned or
-- suspended profile as "may not act" — so the guard stopped the worker.
--
-- Fix: account_can_act() is TRUE for the account listed in
-- public.video_converter_accounts (the one row 0007 wrote; only a migration can
-- add one). Nothing else changes: the converter is still banned + hidden, the
-- old "Banned users cannot …" row rules still refuse its posts, comments and
-- reactions, and it still holds no role. Every real member who is suspended,
-- banned or under review is still stopped exactly as before.
--
-- Rollback: supabase/rollback/20261116_1500_a1_guard_skips_converter_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261116_1500_a1_guard_skips_converter.sql
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
  IF to_regprocedure('public.account_can_act(uuid)') IS NULL THEN
    RAISE EXCEPTION 'A1-FIX-PRE-001: account_can_act (20261115_1310) is missing on this lane';
  END IF;
  IF to_regclass('public.video_converter_accounts') IS NULL THEN
    RAISE EXCEPTION 'A1-FIX-PRE-002: video_converter_accounts (20261012_0002) is missing on this lane';
  END IF;
END
$pre$;

CREATE OR REPLACE FUNCTION public.account_can_act(_uid uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT _uid IS NULL
      OR EXISTS (SELECT 1 FROM public.video_converter_accounts c WHERE c.user_id = _uid)
      OR (NOT EXISTS (SELECT 1 FROM public.account_states s WHERE s.user_id = _uid AND s.state <> 'active')
          AND NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _uid AND (p.is_suspended OR coalesce(p.is_banned, false))));
$fn$;
REVOKE ALL ON FUNCTION public.account_can_act(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.account_can_act(uuid) TO service_role;

DO $post$
DECLARE _c int; _blocked int;
BEGIN
  SELECT count(*) INTO _c FROM public.video_converter_accounts;
  SELECT count(*) INTO _blocked FROM public.profiles p WHERE NOT public.account_can_act(p.id);
  RAISE NOTICE 'A1-FIX: converter account(s) let through = %; profiles still stopped by the guard = %', _c, _blocked;
END
$post$;

COMMIT;

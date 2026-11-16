-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261116_1400 admin users v4. Drops the three functions 1400 added.
-- The Users page then shows the previous list by itself (AdminMembersTable
-- falls back to AdminUsers when admin_search_users_v4 is missing); v2/v3 stay.
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

DO $pre$
BEGIN
  IF to_regprocedure('public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer)') IS NULL
     OR to_regprocedure('public.admin_user_facets(text, text, text, text, text, text)') IS NULL
     OR to_regprocedure('public.member_status_of(boolean, boolean, text)') IS NULL THEN
    RAISE EXCEPTION 'AU-1400-RB-PRE-001: 1400 is not (fully) applied — nothing to roll back';
  END IF;
END
$pre$;

DROP FUNCTION public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer);
DROP FUNCTION public.admin_user_facets(text, text, text, text, text, text);
DROP FUNCTION public.member_status_of(boolean, boolean, text);

DO $post$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
              AND proname IN ('member_status_of', 'admin_search_users_v4', 'admin_user_facets')) THEN
    RAISE EXCEPTION 'AU-1400-RB-POST-001: a 1400 function is still present';
  END IF;
  IF to_regprocedure('public.admin_search_users_v3(text, text, text, text, text, integer, integer)') IS NULL THEN
    RAISE EXCEPTION 'AU-1400-RB-POST-002: admin_search_users_v3 is missing — the previous list would break';
  END IF;
END
$post$;

COMMIT;

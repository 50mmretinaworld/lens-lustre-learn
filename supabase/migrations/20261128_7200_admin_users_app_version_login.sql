-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 20261128_7200 · Admin → Users: app version + last login (Owner bug list 28 Nov, item 17). Lanes: staging, production.
--
-- NEW function admin_search_users_v5 = admin_search_users_v4 (20261116_1400, unchanged and kept) plus three columns:
--   last_sign_in_at  auth.users.last_sign_in_at — the member's last log-in
--   app_version      the app version the member's phone last reported (push_tokens.app_version, newest device;
--                    else push_permission_state.app_version). NULL = never reported (website only, or an app
--                    older than the push centre of 16 Nov).
--   app_os           'android' / 'ios' of that device
-- Same filters, sort, paging, admin check (has_role admin), SECURITY DEFINER, search_path ''. Read only.
-- The page reads v5 and falls back to v4 while v5 is missing, so client and SQL may go live in either order.
--
-- Rollback: supabase/rollback/20261128_7200_admin_users_app_version_login_ROLLBACK.sql (DROP v5; v4 untouched)
-- PROBE:    supabase/migrations/PROBE_20261128_7200_admin_users_app_version_login.sql
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regprocedure('public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer)') IS NULL THEN
    RAISE EXCEPTION 'AU-7200-PRE-001: admin_search_users_v4 missing (1400 not applied)';
  END IF;
  IF to_regprocedure('public.admin_search_users_v5(text, text, text, text, text, text, text, integer, integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'AU-7200-PRE-002: admin_search_users_v5 already exists — roll back first';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'push_tokens'
        AND column_name IN ('user_id', 'platform', 'app_version', 'updated_at')) <> 4
     OR to_regclass('public.push_permission_state') IS NULL THEN
    RAISE EXCEPTION 'AU-7200-PRE-003: push_tokens / push_permission_state not as expected (1500 not applied)';
  END IF;
END
$pre$;

CREATE FUNCTION public.admin_search_users_v5(
  _query    text    DEFAULT '',
  _role     text    DEFAULT NULL,
  _badge    text    DEFAULT NULL,
  _platform text    DEFAULT NULL,
  _status   text    DEFAULT NULL,
  _active   text    DEFAULT NULL,
  _sort     text    DEFAULT 'joined_desc',
  _limit    integer DEFAULT 50,
  _offset   integer DEFAULT 0
)
RETURNS TABLE (
  id                uuid,
  email             text,
  full_name         text,
  avatar_url        text,
  custom_url        text,
  bio               text,
  created_at        timestamp with time zone,
  last_active_at    timestamp with time zone,
  last_platform     text,
  roles             text[],
  badges            text[],
  status            text,
  suspended_until   timestamp with time zone,
  suspension_reason text,
  review_reason     text,
  total_count       bigint,
  last_sign_in_at   timestamp with time zone,
  app_version       text,
  app_os            text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  -- v4 does the admin check, the filters, the sort and the paging; v5 only adds three columns per row.
  RETURN QUERY
  SELECT v.id, v.email, v.full_name, v.avatar_url, v.custom_url, v.bio, v.created_at, v.last_active_at,
         v.last_platform, v.roles, v.badges, v.status, v.suspended_until, v.suspension_reason, v.review_reason,
         v.total_count,
         au.last_sign_in_at,
         coalesce(dev.app_version, perm.app_version)::text,
         coalesce(dev.platform, perm.platform)::text
    FROM public.admin_search_users_v4(_query, _role, _badge, _platform, _status, _active, _sort, _limit, _offset)
         WITH ORDINALITY AS v
    LEFT JOIN auth.users au ON au.id = v.id
    LEFT JOIN LATERAL (
      SELECT t.app_version, t.platform FROM public.push_tokens t
       WHERE t.user_id = v.id AND t.platform IN ('android', 'ios') AND t.app_version IS NOT NULL
       ORDER BY t.updated_at DESC LIMIT 1
    ) dev ON true
    LEFT JOIN public.push_permission_state perm ON perm.user_id = v.id AND perm.platform IN ('android', 'ios')
   ORDER BY v.ordinality;
END
$fn$;

REVOKE ALL ON FUNCTION public.admin_search_users_v5(text, text, text, text, text, text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_search_users_v5(text, text, text, text, text, text, text, integer, integer) TO authenticated;

COMMIT;

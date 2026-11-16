-- ═══════════════════════════════════════════════════════════════════════════
-- 20261116_1400 · Admin → Users members table (Owner, 2026-11-16: "suspended /
-- banned users can't see … Now vs New"; approved "users table OK").
--
-- EXPAND ONLY. Adds three functions; changes and drops nothing. v2 and v3 stay
-- (the table falls back to the previous list when v4 is missing).
--
--   member_status_of(is_banned, is_suspended, account_state) → text
--     ONE rule for a member's status, in the order account_can_act() blocks:
--     banned › suspended › deletion_requested › under_review › active.
--     Internal: no role may EXECUTE it; the two admin functions call it as owner.
--
--   admin_search_users_v4(_query, _role, _badge, _platform, _status, _active, _sort, _limit, _offset)
--     One row per member with everything the table shows (roles[], badges[],
--     last_active_at, last_platform, custom_url, status, reasons) + total_count.
--     EVERY filter, the sort and the paging run here, before LIMIT — so no
--     member can fall off a page (the 2026-08-21 lesson, see AdminUsers.tsx).
--     _query matches name, e-mail or @handle.
--
--   admin_user_facets(_query, _role, _badge, _platform, _status, _active)
--     Status-tab counts (every filter but status) and platform counts (every
--     filter but platform). Aggregates only.
--
-- Both admin functions: SECURITY DEFINER, search_path '', has_role(admin) gate,
-- EXECUTE authenticated only — the same shape as v3 (20261103_0101).
-- Rollback: supabase/rollback/20261116_1400_admin_users_v4_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261116_1400_admin_users_v4.sql
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
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'profiles'
         AND column_name IN ('id', 'full_name', 'avatar_url', 'bio', 'custom_url', 'created_at',
                             'last_active_at', 'last_platform', 'is_banned', 'is_suspended',
                             'suspended_until', 'suspension_reason')) <> 12 THEN
    RAISE EXCEPTION 'AU-1400-PRE-001: public.profiles is missing a column the table reads — refusing';
  END IF;
  IF to_regclass('public.user_roles') IS NULL OR to_regclass('public.user_badges') IS NULL
     OR to_regclass('public.account_states') IS NULL THEN
    RAISE EXCEPTION 'AU-1400-PRE-002: user_roles / user_badges / account_states missing — refusing';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
              AND proname IN ('member_status_of', 'admin_search_users_v4', 'admin_user_facets')) THEN
    RAISE EXCEPTION 'AU-1400-PRE-003: a 1400 function already exists — roll back first';
  END IF;
END
$pre$;

CREATE FUNCTION public.member_status_of(_is_banned boolean, _is_suspended boolean, _account_state text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN coalesce(_is_banned, false)          THEN 'banned'
    WHEN coalesce(_is_suspended, false)       THEN 'suspended'
    WHEN _account_state = 'deletion_requested' THEN 'deletion_requested'
    WHEN _account_state = 'under_review'       THEN 'under_review'
    ELSE 'active'
  END;
$fn$;

CREATE FUNCTION public.admin_search_users_v4(
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
  total_count       bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_limit    integer := least(greatest(coalesce(_limit, 50), 1), 200);
  v_offset   integer := greatest(coalesce(_offset, 0), 0);
  v_query    text    := coalesce(btrim(_query), '');
  v_role     text    := nullif(coalesce(_role, ''), '');
  v_badge    text    := nullif(coalesce(_badge, ''), '');
  v_platform text    := nullif(coalesce(_platform, ''), '');
  v_status   text    := nullif(coalesce(_status, ''), '');
  v_active   text    := nullif(coalesce(_active, ''), '');
  v_sort     text    := coalesce(nullif(_sort, ''), 'joined_desc');
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF v_platform IS NOT NULL AND v_platform NOT IN ('app', 'web', 'unknown') THEN
    RAISE EXCEPTION 'admin_search_users_v4: _platform must be NULL, app, web or unknown' USING ERRCODE = '22023';
  END IF;
  IF v_status IS NOT NULL AND v_status NOT IN ('active', 'suspended', 'banned', 'under_review', 'deletion_requested') THEN
    RAISE EXCEPTION 'admin_search_users_v4: unknown _status %', v_status USING ERRCODE = '22023';
  END IF;
  IF v_active IS NOT NULL AND v_active NOT IN ('24h', '7d', '30d', 'inactive90') THEN
    RAISE EXCEPTION 'admin_search_users_v4: unknown _active %', v_active USING ERRCODE = '22023';
  END IF;
  IF v_sort NOT IN ('joined_desc', 'joined_asc', 'name_asc', 'name_desc', 'active_desc', 'active_asc') THEN
    RAISE EXCEPTION 'admin_search_users_v4: unknown _sort %', v_sort USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH matched AS (
    SELECT p.id, au.email::text AS email, p.full_name, p.avatar_url, p.custom_url, p.bio, p.created_at,
           p.last_active_at, p.last_platform,
           public.member_status_of(p.is_banned, p.is_suspended, s.state) AS status,
           p.suspended_until, p.suspension_reason, s.reason AS review_reason
      FROM public.profiles p
      LEFT JOIN auth.users au ON au.id = p.id
      LEFT JOIN public.account_states s ON s.user_id = p.id
     WHERE (
             v_query = ''
             OR p.full_name  ILIKE '%' || v_query || '%'
             OR au.email     ILIKE '%' || v_query || '%'
             OR p.custom_url ILIKE '%' || ltrim(v_query, '@') || '%'
           )
       AND (v_role IS NULL
            OR EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p.id AND ur.role::text = v_role))
       AND (v_badge IS NULL
            OR EXISTS (SELECT 1 FROM public.user_badges ub WHERE ub.user_id = p.id AND ub.badge_type = v_badge))
       AND (v_platform IS NULL
            OR (v_platform = 'unknown' AND p.last_platform IS NULL)
            OR p.last_platform = v_platform)
       AND (v_active IS NULL
            OR (v_active = '24h' AND p.last_active_at >= now() - interval '24 hours')
            OR (v_active = '7d'  AND p.last_active_at >= now() - interval '7 days')
            OR (v_active = '30d' AND p.last_active_at >= now() - interval '30 days')
            OR (v_active = 'inactive90' AND (p.last_active_at IS NULL OR p.last_active_at < now() - interval '90 days')))
  ),
  filtered AS (
    SELECT m.*, count(*) OVER () AS total_count
      FROM matched m
     WHERE v_status IS NULL OR m.status = v_status
  ),
  paged AS (
    SELECT f.*
      FROM filtered f
     ORDER BY
       CASE WHEN v_sort = 'joined_desc' THEN f.created_at END DESC,
       CASE WHEN v_sort = 'joined_asc'  THEN f.created_at END ASC,
       CASE WHEN v_sort = 'name_asc'    THEN lower(f.full_name) END ASC NULLS LAST,
       CASE WHEN v_sort = 'name_desc'   THEN lower(f.full_name) END DESC NULLS LAST,
       CASE WHEN v_sort = 'active_desc' THEN f.last_active_at END DESC NULLS LAST,
       CASE WHEN v_sort = 'active_asc'  THEN f.last_active_at END ASC NULLS FIRST,
       f.created_at DESC, f.id DESC
     LIMIT v_limit OFFSET v_offset
  )
  SELECT pg.id, pg.email, pg.full_name::text, pg.avatar_url::text, pg.custom_url::text, pg.bio::text, pg.created_at,
         pg.last_active_at, pg.last_platform::text,
         coalesce((SELECT array_agg(ur.role::text ORDER BY ur.role::text) FROM public.user_roles ur WHERE ur.user_id = pg.id), '{}'::text[]),
         coalesce((SELECT array_agg(ub.badge_type::text ORDER BY ub.badge_type::text) FROM public.user_badges ub WHERE ub.user_id = pg.id), '{}'::text[]),
         pg.status, pg.suspended_until, pg.suspension_reason::text, pg.review_reason::text, pg.total_count
    FROM paged pg
   ORDER BY
     CASE WHEN v_sort = 'joined_desc' THEN pg.created_at END DESC,
     CASE WHEN v_sort = 'joined_asc'  THEN pg.created_at END ASC,
     CASE WHEN v_sort = 'name_asc'    THEN lower(pg.full_name) END ASC NULLS LAST,
     CASE WHEN v_sort = 'name_desc'   THEN lower(pg.full_name) END DESC NULLS LAST,
     CASE WHEN v_sort = 'active_desc' THEN pg.last_active_at END DESC NULLS LAST,
     CASE WHEN v_sort = 'active_asc'  THEN pg.last_active_at END ASC NULLS FIRST,
     pg.created_at DESC, pg.id DESC;
END
$fn$;

CREATE FUNCTION public.admin_user_facets(
  _query    text DEFAULT '',
  _role     text DEFAULT NULL,
  _badge    text DEFAULT NULL,
  _platform text DEFAULT NULL,
  _status   text DEFAULT NULL,
  _active   text DEFAULT NULL
)
RETURNS TABLE (
  all_count                bigint,
  active_count             bigint,
  suspended_count          bigint,
  banned_count             bigint,
  under_review_count       bigint,
  deletion_requested_count bigint,
  platform_all_count       bigint,
  app_count                bigint,
  web_count                bigint,
  unknown_count            bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_query    text := coalesce(btrim(_query), '');
  v_role     text := nullif(coalesce(_role, ''), '');
  v_badge    text := nullif(coalesce(_badge, ''), '');
  v_platform text := nullif(coalesce(_platform, ''), '');
  v_status   text := nullif(coalesce(_status, ''), '');
  v_active   text := nullif(coalesce(_active, ''), '');
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT p.last_platform,
           public.member_status_of(p.is_banned, p.is_suspended, s.state) AS status
      FROM public.profiles p
      LEFT JOIN auth.users au ON au.id = p.id
      LEFT JOIN public.account_states s ON s.user_id = p.id
     WHERE (
             v_query = ''
             OR p.full_name  ILIKE '%' || v_query || '%'
             OR au.email     ILIKE '%' || v_query || '%'
             OR p.custom_url ILIKE '%' || ltrim(v_query, '@') || '%'
           )
       AND (v_role IS NULL
            OR EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p.id AND ur.role::text = v_role))
       AND (v_badge IS NULL
            OR EXISTS (SELECT 1 FROM public.user_badges ub WHERE ub.user_id = p.id AND ub.badge_type = v_badge))
       AND (v_active IS NULL
            OR (v_active = '24h' AND p.last_active_at >= now() - interval '24 hours')
            OR (v_active = '7d'  AND p.last_active_at >= now() - interval '7 days')
            OR (v_active = '30d' AND p.last_active_at >= now() - interval '30 days')
            OR (v_active = 'inactive90' AND (p.last_active_at IS NULL OR p.last_active_at < now() - interval '90 days')))
  ),
  marked AS (
    SELECT b.last_platform, b.status,
           (v_platform IS NULL OR (v_platform = 'unknown' AND b.last_platform IS NULL) OR b.last_platform = v_platform) AS platform_ok,
           (v_status IS NULL OR b.status = v_status) AS status_ok
      FROM base b
  )
  SELECT count(*) FILTER (WHERE platform_ok),
         count(*) FILTER (WHERE platform_ok AND status = 'active'),
         count(*) FILTER (WHERE platform_ok AND status = 'suspended'),
         count(*) FILTER (WHERE platform_ok AND status = 'banned'),
         count(*) FILTER (WHERE platform_ok AND status = 'under_review'),
         count(*) FILTER (WHERE platform_ok AND status = 'deletion_requested'),
         count(*) FILTER (WHERE status_ok),
         count(*) FILTER (WHERE status_ok AND last_platform = 'app'),
         count(*) FILTER (WHERE status_ok AND last_platform = 'web'),
         count(*) FILTER (WHERE status_ok AND last_platform IS NULL)
    FROM marked;
END
$fn$;

COMMENT ON FUNCTION public.member_status_of(boolean, boolean, text) IS
  '20261116_1400: one status per member — banned > suspended > deletion_requested > under_review > active (account_can_act order). Internal.';
COMMENT ON FUNCTION public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer) IS
  '20261116_1400: Admin Users table rows (roles, badges, activity, status) — every filter, sort and page in SQL before LIMIT. Admin only.';
COMMENT ON FUNCTION public.admin_user_facets(text, text, text, text, text, text) IS
  '20261116_1400: status-tab and platform counts for the current filters. Admin only. Aggregates only.';

REVOKE ALL ON FUNCTION public.member_status_of(boolean, boolean, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_user_facets(text, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_user_facets(text, text, text, text, text, text) TO authenticated;

DO $post$
DECLARE f oid; n text;
BEGIN
  FOREACH n IN ARRAY ARRAY[
    'public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer)',
    'public.admin_user_facets(text, text, text, text, text, text)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL OR NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=""'] FROM pg_proc WHERE oid = f) THEN
      RAISE EXCEPTION 'AU-1400-POST-001: % missing or not SECURITY DEFINER with search_path=""', n;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) x WHERE p.oid = f AND x.grantee = 0) THEN
      RAISE EXCEPTION 'AU-1400-POST-002: % EXECUTE must be authenticated (not anon, not PUBLIC)', n;
    END IF;
    IF position('has_role(auth.uid(), ''admin'')' IN pg_get_functiondef(f)) = 0 THEN
      RAISE EXCEPTION 'AU-1400-POST-003: % lost the admin gate', n;
    END IF;
  END LOOP;
  f := to_regprocedure('public.member_status_of(boolean, boolean, text)');
  IF f IS NULL
     OR has_function_privilege('anon', f, 'EXECUTE')
     OR has_function_privilege('authenticated', f, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) x WHERE p.oid = f AND x.grantee = 0) THEN
    RAISE EXCEPTION 'AU-1400-POST-004: member_status_of missing or callable by a client role';
  END IF;
  IF public.member_status_of(true, true, 'under_review') <> 'banned'
     OR public.member_status_of(false, true, 'deletion_requested') <> 'suspended'
     OR public.member_status_of(false, false, 'deletion_requested') <> 'deletion_requested'
     OR public.member_status_of(NULL, NULL, 'under_review') <> 'under_review'
     OR public.member_status_of(false, false, NULL) <> 'active'
     OR public.member_status_of(false, false, 'active') <> 'active' THEN
    RAISE EXCEPTION 'AU-1400-POST-005: member_status_of order is wrong';
  END IF;
END
$post$;

COMMIT;

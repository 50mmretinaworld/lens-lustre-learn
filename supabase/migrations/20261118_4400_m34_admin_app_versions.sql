-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_4400 · M34 — Admin: which app version each member uses (Owner 23 Nov 2026)
--
--  Owner: "In Admin, seeing who is using the App — write which App version each user is using; who is using an old
--  version / last updated version admin wants to see. iOS too."
--
--  READ-ONLY. No table changes. The data is already collected:
--    push_permission_state  one row per member, written on EVERY signed-in app start (report_push_permission,
--                           app builds >= Android 1.2.50 and the iOS build): platform, app_version, updated_at
--                           (= last time the app was opened).
--    push_tokens            device tokens; older app builds left app_version NULL.
--    profiles.last_platform 'app' | 'web' | NULL (last session's platform).
--
--  One rule for "which app is this member on" (member_app_rows, not callable by clients):
--    the push_permission_state row when its platform is android / ios, else the newest android / ios push_tokens
--    row (its version may be NULL = an older app that did not report one).
--
--  admin_member_apps(_ids uuid[])                     per member (max 200): os, app_version, seen_at, push on/off
--  admin_app_versions()                               jsonb summary: per (os, version) members + opened in 7 days;
--                                                     older app (no version); website only; not recorded
--  admin_app_version_members(_os, _version, _limit, _offset)
--                                                     the members behind one summary row (+ total_count)
--      _os 'android' | 'ios' with _version  → that build
--      _os 'older'                          → app members with no version recorded
--      _os 'web'                            → website only (no app record, last platform web)
--
--  All three: SECURITY DEFINER, search_path '', has_role(admin) gate (insufficient_privilege), EXECUTE authenticated
--  only (not anon, not PUBLIC).
--
-- Rollback: supabase/rollback/20261118_4400_m34_admin_app_versions_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_4400_m34_admin_app_versions.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.admin_app_versions()') IS NOT NULL THEN
    RAISE EXCEPTION 'M34-PRE-001: admin_app_versions already exists — not re-applying';
  END IF;
  IF to_regclass('public.push_permission_state') IS NULL OR to_regclass('public.push_tokens') IS NULL THEN
    RAISE EXCEPTION 'M34-PRE-002: push_permission_state or push_tokens missing (20261116_1500 push centre first)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'push_tokens' AND column_name = 'app_version') THEN
    RAISE EXCEPTION 'M34-PRE-003: push_tokens.app_version missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. the one rule: which app (os + version) a member is on ───────────────
-- _ids NULL = every member. Not callable by clients; the admin functions below run it as their owner.
CREATE FUNCTION public.member_app_rows(_ids uuid[])
RETURNS TABLE (user_id uuid, os text, app_version text, seen_at timestamptz, push text)
LANGUAGE sql
STABLE
SET search_path = ''
AS $fn$
  WITH pps AS (
    SELECT s.user_id, s.platform, s.app_version, s.updated_at, s.permission
      FROM public.push_permission_state s
     WHERE s.platform IN ('android', 'ios')
       AND (_ids IS NULL OR s.user_id = ANY (_ids))
  ), tok AS (
    SELECT DISTINCT ON (t.user_id) t.user_id, t.platform, t.app_version, t.updated_at
      FROM public.push_tokens t
     WHERE t.platform IN ('android', 'ios')
       AND (_ids IS NULL OR t.user_id = ANY (_ids))
     ORDER BY t.user_id, t.updated_at DESC
  )
  SELECT coalesce(p.user_id, k.user_id),
         CASE WHEN p.user_id IS NOT NULL THEN p.platform ELSE k.platform END,
         CASE WHEN p.user_id IS NOT NULL THEN p.app_version ELSE k.app_version END,
         CASE WHEN p.user_id IS NOT NULL THEN p.updated_at ELSE k.updated_at END,
         CASE WHEN p.user_id IS NULL THEN 'on' WHEN p.permission = 'granted' THEN 'on' ELSE 'off' END
    FROM pps p
    FULL JOIN tok k ON k.user_id = p.user_id
$fn$;

-- ── 2. per member, for the rows on screen ──────────────────────────────────
CREATE FUNCTION public.admin_member_apps(_ids uuid[])
RETURNS TABLE (user_id uuid, os text, app_version text, seen_at timestamptz, push text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(cardinality(_ids), 0) > 200 THEN
    RAISE EXCEPTION 'admin_member_apps: at most 200 ids' USING ERRCODE = '22023';
  END IF;
  IF coalesce(cardinality(_ids), 0) = 0 THEN
    RETURN;
  END IF;
  RETURN QUERY
    SELECT r.user_id, r.os, r.app_version, r.seen_at, r.push
      FROM public.member_app_rows(_ids) r
      JOIN public.profiles pr ON pr.id = r.user_id;
END
$fn$;

-- ── 3. the summary card ────────────────────────────────────────────────────
CREATE FUNCTION public.admin_app_versions()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  _r jsonb;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  WITH a AS (
    SELECT r.user_id, r.os, r.app_version, r.seen_at
      FROM public.member_app_rows(NULL) r
      JOIN public.profiles pr ON pr.id = r.user_id
  ), v AS (
    SELECT a.os, a.app_version, count(*) AS members,
           count(*) FILTER (WHERE a.seen_at > now() - interval '7 days') AS active_7d,
           max(a.seen_at) AS last_seen
      FROM a
     WHERE a.app_version IS NOT NULL
     GROUP BY a.os, a.app_version
  ), rest AS (
    SELECT p.id, p.last_platform, p.last_active_at
      FROM public.profiles p
     WHERE NOT EXISTS (SELECT 1 FROM a WHERE a.user_id = p.id)
  )
  SELECT jsonb_build_object(
    'checked_at', now(),
    'versions', coalesce((SELECT jsonb_agg(jsonb_build_object(
                    'os', v.os, 'version', v.app_version, 'members', v.members,
                    'active_7d', v.active_7d, 'last_seen', v.last_seen) ORDER BY v.os, v.members DESC) FROM v), '[]'::jsonb),
    'older_app', jsonb_build_object(
        'members', (SELECT count(*) FROM a WHERE a.app_version IS NULL)
                 + (SELECT count(*) FROM rest WHERE rest.last_platform = 'app'),
        'active_7d', (SELECT count(*) FROM a WHERE a.app_version IS NULL AND a.seen_at > now() - interval '7 days')
                   + (SELECT count(*) FROM rest WHERE rest.last_platform = 'app' AND rest.last_active_at > now() - interval '7 days')),
    'website_only', jsonb_build_object(
        'members', (SELECT count(*) FROM rest WHERE rest.last_platform = 'web'),
        'active_7d', (SELECT count(*) FROM rest WHERE rest.last_platform = 'web' AND rest.last_active_at > now() - interval '7 days')),
    'not_recorded', (SELECT count(*) FROM rest WHERE rest.last_platform IS NULL),
    'total', (SELECT count(*) FROM public.profiles))
  INTO _r;
  RETURN _r;
END
$fn$;

-- ── 4. the members behind one summary row ──────────────────────────────────
CREATE FUNCTION public.admin_app_version_members(
  _os      text,
  _version text,
  _limit   integer DEFAULT 100,
  _offset  integer DEFAULT 0
)
RETURNS TABLE (
  id          uuid,
  full_name   text,
  avatar_url  text,
  custom_url  text,
  os          text,
  app_version text,
  seen_at     timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
#variable_conflict use_column
DECLARE
  v_os      text    := nullif(btrim(coalesce(_os, '')), '');
  v_version text    := nullif(btrim(coalesce(_version, '')), '');
  v_limit   integer := least(greatest(coalesce(_limit, 100), 1), 200);
  v_offset  integer := greatest(coalesce(_offset, 0), 0);
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_os IS NULL OR v_os NOT IN ('android', 'ios', 'older', 'web') THEN
    RAISE EXCEPTION 'admin_app_version_members: _os must be android, ios, older or web' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
    WITH a AS (
      SELECT r.user_id, r.os, r.app_version, r.seen_at FROM public.member_app_rows(NULL) r
    ), pick AS (
      SELECT a.user_id, a.os, a.app_version, a.seen_at
        FROM a
       WHERE (v_os IN ('android', 'ios') AND a.os = v_os AND a.app_version IS NOT DISTINCT FROM v_version)
          OR (v_os = 'older' AND a.app_version IS NULL)
      UNION ALL
      SELECT p.id, NULL::text, NULL::text, p.last_active_at::timestamptz
        FROM public.profiles p
       WHERE v_os IN ('older', 'web')
         AND p.last_platform = CASE WHEN v_os = 'older' THEN 'app' ELSE 'web' END
         AND NOT EXISTS (SELECT 1 FROM a WHERE a.user_id = p.id)
    )
    SELECT pr.id, pr.full_name::text, pr.avatar_url::text, pr.custom_url::text,
           k.os, k.app_version, k.seen_at, count(*) OVER ()
      FROM pick k
      JOIN public.profiles pr ON pr.id = k.user_id
     ORDER BY k.seen_at DESC NULLS LAST, pr.id
     LIMIT v_limit OFFSET v_offset;
END
$fn$;

-- ── 5. grants ──────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.member_app_rows(uuid[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_member_apps(uuid[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_app_versions() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_app_version_members(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_member_apps(uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_app_versions() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_app_version_members(text, text, integer, integer) TO authenticated, service_role;

-- ── 6. post checks ─────────────────────────────────────────────────────────
DO $post$
DECLARE f oid; n text;
BEGIN
  FOREACH n IN ARRAY ARRAY[
    'public.admin_member_apps(uuid[])',
    'public.admin_app_versions()',
    'public.admin_app_version_members(text, text, integer, integer)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL OR NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=""'] FROM pg_proc WHERE oid = f) THEN
      RAISE EXCEPTION 'M34-POST-001: % missing or not SECURITY DEFINER with search_path=""', n;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) x WHERE p.oid = f AND x.grantee = 0) THEN
      RAISE EXCEPTION 'M34-POST-002: % EXECUTE must be authenticated (not anon, not PUBLIC)', n;
    END IF;
    IF position('has_role(auth.uid(), ''admin'')' IN pg_get_functiondef(f)) = 0 THEN
      RAISE EXCEPTION 'M34-POST-003: % lost the admin gate', n;
    END IF;
  END LOOP;
  f := to_regprocedure('public.member_app_rows(uuid[])');
  IF f IS NULL
     OR has_function_privilege('anon', f, 'EXECUTE')
     OR has_function_privilege('authenticated', f, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) x WHERE p.oid = f AND x.grantee = 0) THEN
    RAISE EXCEPTION 'M34-POST-004: member_app_rows missing or callable by a client role';
  END IF;
  RAISE NOTICE 'M34 applied — admin app versions: % member(s) with an app record',
    (SELECT count(*) FROM public.member_app_rows(NULL));
END
$post$;

COMMIT;

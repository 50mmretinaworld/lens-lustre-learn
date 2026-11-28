-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBE · 20261128_7200 admin_search_users_v5. WRITES NOTHING (ROLLBACK). FAILS before apply.
--   B1  v5 exists, SECURITY DEFINER, search_path '', anon cannot run it, authenticated can.
--   B2  a caller who is not an admin is refused ('Not authorized', from v4 inside).
--   B3  as an admin: same rows and order as v4 for the same arguments; the three new columns are present.
-- Prints counts only.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';

DO $p$
DECLARE
  _fn regprocedure := to_regprocedure('public.admin_search_users_v5(text, text, text, text, text, text, text, integer, integer)');
  _admin uuid;
  _v4 uuid[];
  _v5 uuid[];
  _withver bigint;
  _withlogin bigint;
  _refused boolean := false;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  -- B1
  IF _fn IS NULL THEN RAISE EXCEPTION 'PROBE FAIL B1: admin_search_users_v5 missing (7200 not applied)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = _fn AND prosecdef AND proconfig @> ARRAY['search_path=""']) THEN
    RAISE EXCEPTION 'PROBE FAIL B1: v5 not SECURITY DEFINER with search_path ''''';
  END IF;
  IF has_function_privilege('anon', _fn, 'EXECUTE') THEN RAISE EXCEPTION 'PROBE FAIL B1: anon can run v5'; END IF;
  IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE') THEN RAISE EXCEPTION 'PROBE FAIL B1: authenticated cannot run v5'; END IF;

  -- B2: no admin in the session
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM 1 FROM public.admin_search_users_v5('', NULL, NULL, NULL, NULL, NULL, 'joined_desc', 5, 0);
  EXCEPTION WHEN OTHERS THEN
    _refused := SQLERRM LIKE '%Not authorized%';
  END;
  IF NOT _refused THEN RAISE EXCEPTION 'PROBE FAIL B2: a non-admin was not refused'; END IF;

  -- B3: as an admin
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role = 'admin' ORDER BY r.user_id LIMIT 1;
  IF _admin IS NULL THEN RAISE EXCEPTION 'PROBE FAIL: no admin to test with'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin::text, 'role', 'authenticated')::text, true);
  SELECT array_agg(x.id ORDER BY x.n) INTO _v4
    FROM (SELECT v.id, row_number() OVER () AS n FROM public.admin_search_users_v4('', NULL, NULL, NULL, NULL, NULL, 'active_desc', 50, 0) v) x;
  SELECT array_agg(x.id ORDER BY x.n), count(*) FILTER (WHERE x.app_version IS NOT NULL), count(*) FILTER (WHERE x.last_sign_in_at IS NOT NULL)
    INTO _v5, _withver, _withlogin
    FROM (SELECT v.id, v.app_version, v.last_sign_in_at, row_number() OVER () AS n
            FROM public.admin_search_users_v5('', NULL, NULL, NULL, NULL, NULL, 'active_desc', 50, 0) v) x;
  IF _v4 IS DISTINCT FROM _v5 THEN RAISE EXCEPTION 'PROBE FAIL B3: v5 rows/order differ from v4'; END IF;

  RAISE NOTICE 'PROBE PASS 7200: B1 structure + grants, B2 non-admin refused, B3 same % rows as v4 (% with app version, % with last login).',
    coalesce(array_length(_v5, 1), 0), _withver, _withlogin;
END
$p$;

ROLLBACK;

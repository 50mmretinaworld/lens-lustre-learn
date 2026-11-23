-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_4400 — M34 admin app versions. One transaction, ROLLBACK.
-- Before 20261118_4400: FAIL (functions missing). After: M34 PASS.
--   V1  the three admin functions exist, SECURITY DEFINER + search_path '', authenticated only (anon / PUBLIC cannot
--       execute); member_app_rows is not callable by any client role
--   V2  a member (not admin) is refused by all three (insufficient_privilege)
--   V3  rows planted in this transaction come back right for the admin:
--         m1 android 9.9.901 (opened now, push on)  m2 android 9.9.901 (opened 10 days ago, push off)
--         m3 ios 9.9.902                            m4 older app: android token without a version
--         m5 website only (no app record, last platform web)
--       admin_member_apps → each member's os / version / push; admin_app_versions → 9.9.901 = 2 members, 1 in 7 days,
--       9.9.902 = 1; admin_app_version_members → the right members and total for android 9.9.901, older and web
--   V4  more than 200 ids, or an unknown _os, is refused (22023)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

CREATE FUNCTION pg_temp.set_user(_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _ids uuid[]; _m1 uuid; _m2 uuid; _m3 uuid; _m4 uuid; _m5 uuid; _admin uuid;
  _r jsonb; _e jsonb; _n bigint; _os text; _ver text; _push text; _hit boolean;
  n text; f oid;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M34 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.admin_app_versions()') IS NULL
     OR to_regprocedure('public.admin_member_apps(uuid[])') IS NULL
     OR to_regprocedure('public.admin_app_version_members(text, text, integer, integer)') IS NULL THEN
    RAISE EXCEPTION 'M34 FAIL: admin app version functions missing — expected before 20261118_4400';
  END IF;

  -- V1
  FOREACH n IN ARRAY ARRAY[
    'public.admin_member_apps(uuid[])',
    'public.admin_app_versions()',
    'public.admin_app_version_members(text, text, integer, integer)'] LOOP
    f := to_regprocedure(n);
    IF NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=""'] FROM pg_proc WHERE oid = f) THEN
      _fail := _fail || ('V1 ' || n || ' not SECURITY DEFINER with search_path ''''');
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') THEN _fail := _fail || ('V1 anon can execute ' || n); END IF;
    IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN _fail := _fail || ('V1 authenticated cannot execute ' || n); END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) x WHERE p.oid = f AND x.grantee = 0) THEN
      _fail := _fail || ('V1 PUBLIC can execute ' || n);
    END IF;
  END LOOP;
  f := to_regprocedure('public.member_app_rows(uuid[])');
  IF f IS NULL OR has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
    _fail := _fail || 'V1 member_app_rows missing or callable by a client role';
  END IF;

  -- set-up: five members (not admin) and the admin account; plant their app rows (rolled back at the end)
  SELECT array_agg(s.id) INTO _ids FROM (SELECT p.id FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin')
   ORDER BY p.created_at LIMIT 5) s;
  IF coalesce(array_length(_ids, 1), 0) < 5 THEN RAISE EXCEPTION 'M34 FAIL: need five members to test with'; END IF;
  _m1 := _ids[1]; _m2 := _ids[2]; _m3 := _ids[3]; _m4 := _ids[4]; _m5 := _ids[5];
  SELECT rr.user_id INTO _admin FROM public.user_roles rr JOIN auth.users u ON u.id = rr.user_id WHERE rr.role::text = 'admin' ORDER BY rr.user_id LIMIT 1;
  IF _admin IS NULL THEN RAISE EXCEPTION 'M34 FAIL: need an admin account to test with'; END IF;

  DELETE FROM public.push_permission_state WHERE user_id = ANY (_ids);
  DELETE FROM public.push_tokens WHERE user_id = ANY (_ids);
  INSERT INTO public.push_permission_state (user_id, permission, platform, app_version, updated_at) VALUES
    (_m1, 'granted', 'android', '9.9.901', now()),
    (_m2, 'denied',  'android', '9.9.901', now() - interval '10 days'),
    (_m3, 'granted', 'ios',     '9.9.902', now()),
    (_m4, 'granted', 'web',     NULL,      now());                     -- a web report must not hide the app token
  INSERT INTO public.push_tokens (user_id, token, platform, app_version, updated_at) VALUES
    (_m4, 'probe-m34-' || gen_random_uuid(), 'android', NULL, now());
  UPDATE public.profiles SET last_platform = 'web', last_active_at = now() WHERE id = _m5;

  -- V2
  PERFORM pg_temp.set_user(_m1);
  BEGIN
    PERFORM public.admin_app_versions();
    _fail := _fail || 'V2 a member read admin_app_versions';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.admin_member_apps(ARRAY[_m1]);
    _fail := _fail || 'V2 a member read admin_member_apps';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.admin_app_version_members('android', '9.9.901', 100, 0);
    _fail := _fail || 'V2 a member read admin_app_version_members';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- V3
  PERFORM pg_temp.set_user(_admin);
  SELECT a.os, a.app_version, a.push INTO _os, _ver, _push FROM public.admin_member_apps(_ids) a WHERE a.user_id = _m1;
  IF _os IS DISTINCT FROM 'android' OR _ver IS DISTINCT FROM '9.9.901' OR _push IS DISTINCT FROM 'on' THEN
    _fail := _fail || format('V3 m1 came back %s %s push %s', _os, _ver, _push);
  END IF;
  SELECT a.os, a.app_version, a.push INTO _os, _ver, _push FROM public.admin_member_apps(_ids) a WHERE a.user_id = _m2;
  IF _os IS DISTINCT FROM 'android' OR _ver IS DISTINCT FROM '9.9.901' OR _push IS DISTINCT FROM 'off' THEN
    _fail := _fail || format('V3 m2 came back %s %s push %s', _os, _ver, _push);
  END IF;
  SELECT a.os, a.app_version INTO _os, _ver FROM public.admin_member_apps(_ids) a WHERE a.user_id = _m3;
  IF _os IS DISTINCT FROM 'ios' OR _ver IS DISTINCT FROM '9.9.902' THEN
    _fail := _fail || format('V3 m3 came back %s %s', _os, _ver);
  END IF;
  _os := 'x'; _ver := 'x';
  SELECT a.os, a.app_version INTO _os, _ver FROM public.admin_member_apps(_ids) a WHERE a.user_id = _m4;
  IF _os IS DISTINCT FROM 'android' OR _ver IS NOT NULL THEN
    _fail := _fail || format('V3 m4 (older app) came back %s %s', _os, _ver);
  END IF;
  IF EXISTS (SELECT 1 FROM public.admin_member_apps(_ids) a WHERE a.user_id = _m5) THEN
    _fail := _fail || 'V3 m5 (website only) has an app row';
  END IF;

  _r := public.admin_app_versions();
  SELECT e INTO _e FROM jsonb_array_elements(_r -> 'versions') e WHERE e ->> 'os' = 'android' AND e ->> 'version' = '9.9.901';
  IF (_e ->> 'members')::int IS DISTINCT FROM 2 OR (_e ->> 'active_7d')::int IS DISTINCT FROM 1 THEN
    _fail := _fail || ('V3 summary android 9.9.901 should be 2 members / 1 in 7 days: ' || coalesce(_e::text, '<none>'));
  END IF;
  _e := NULL;
  SELECT e INTO _e FROM jsonb_array_elements(_r -> 'versions') e WHERE e ->> 'os' = 'ios' AND e ->> 'version' = '9.9.902';
  IF (_e ->> 'members')::int IS DISTINCT FROM 1 THEN
    _fail := _fail || ('V3 summary ios 9.9.902 should be 1 member: ' || coalesce(_e::text, '<none>'));
  END IF;
  IF coalesce((_r -> 'older_app' ->> 'members')::int, 0) < 1 OR coalesce((_r -> 'website_only' ->> 'members')::int, 0) < 1 THEN
    _fail := _fail || ('V3 summary older / website counts missing: ' || _r::text);
  END IF;
  IF (_r ->> 'total')::bigint IS DISTINCT FROM (SELECT count(*) FROM public.profiles) THEN
    _fail := _fail || 'V3 summary total is not the member count';
  END IF;

  SELECT max(m.total_count), bool_and(m.id IN (_m1, _m2)) INTO _n, _hit FROM public.admin_app_version_members('android', '9.9.901', 100, 0) m;
  IF _n IS DISTINCT FROM 2 OR NOT coalesce(_hit, false) THEN
    _fail := _fail || format('V3 android 9.9.901 list total %s, only m1/m2: %s', _n, _hit);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.admin_app_version_members('older', NULL, 200, 0) m WHERE m.id = _m4) THEN
    _fail := _fail || 'V3 older-app list does not hold m4';
  END IF;
  IF EXISTS (SELECT 1 FROM public.admin_app_version_members('older', NULL, 200, 0) m WHERE m.id IN (_m1, _m3, _m5)) THEN
    _fail := _fail || 'V3 older-app list holds a member with a version or with no app';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.admin_app_version_members('web', NULL, 200, 0) m WHERE m.id = _m5) THEN
    _fail := _fail || 'V3 website-only list does not hold m5';
  END IF;
  IF EXISTS (SELECT 1 FROM public.admin_app_version_members('web', NULL, 200, 0) m WHERE m.id IN (_m1, _m4)) THEN
    _fail := _fail || 'V3 website-only list holds an app member';
  END IF;

  -- V4
  BEGIN
    PERFORM * FROM public.admin_member_apps(ARRAY(SELECT gen_random_uuid() FROM generate_series(1, 201)));
    _fail := _fail || 'V4 201 ids were accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.admin_app_version_members('windows', NULL, 10, 0);
    _fail := _fail || 'V4 unknown _os was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M34 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M34 PASS — admins see each member''s app (Android / iPhone version, older app, website); members and visitors cannot';
END
$p$;

ROLLBACK;

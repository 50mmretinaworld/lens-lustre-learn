-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBE · 20261126_6600 roles are admin-only. WRITES NOTHING (everything ends in ROLLBACK). FAILS before apply.
--   C1  no permissive INSERT/ALL policy on user_roles, role_applications or user_badges lets a non-admin write.
--   C2  as an ordinary signed-in member: giving yourself a role, a request and a badge are all refused.
--   C3  as an admin: giving a role still works.
-- Prints no member id.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';

DO $p$
DECLARE
  _m      uuid;   -- an ordinary member (no role beyond the plain 'user' one, not already a photographer)
  _admin  uuid;
  _bad    text;
  _ok     boolean;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  -- C1 ── every way in names has_role (admin) ─────────────────────────────────────────────────────────────────
  SELECT string_agg(tablename || ': ' || policyname, '; ') INTO _bad
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename IN ('user_roles', 'role_applications', 'user_badges')
     AND permissive = 'PERMISSIVE' AND cmd IN ('INSERT', 'ALL')
     AND position('has_role' IN coalesce(with_check, qual, '')) = 0;
  IF _bad IS NOT NULL THEN RAISE EXCEPTION 'PROBE FAIL C1: a non-admin write policy remains — %', _bad; END IF;

  SELECT p.id INTO _m
    FROM public.profiles p
   WHERE NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text <> 'user')
     AND NOT coalesce(p.is_banned, false) AND NOT coalesce(p.is_suspended, false)
   ORDER BY p.last_active_at DESC NULLS LAST
   LIMIT 1;
  IF _m IS NULL THEN RAISE EXCEPTION 'PROBE FAIL: no ordinary member to test with'; END IF;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' ORDER BY r.user_id LIMIT 1;
  IF _admin IS NULL THEN RAISE EXCEPTION 'PROBE FAIL: no admin'; END IF;

  -- C2 ── as the member ───────────────────────────────────────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claim.sub', _m::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  _ok := false;
  BEGIN
    INSERT INTO public.user_roles (user_id, role) VALUES (_m, 'registered_photographer');
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  IF NOT _ok THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL C2: a member gave themselves a role'; END IF;

  _ok := false;
  BEGIN
    INSERT INTO public.role_applications (user_id, requested_role, reason, status) VALUES (_m, 'registered_photographer', 'probe', 'pending');
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  IF NOT _ok THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL C2: a member filed a role request'; END IF;

  _ok := false;
  BEGIN
    INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, 'verified', _m);
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  IF NOT _ok THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL C2: a member gave themselves a badge'; END IF;
  RESET ROLE;

  -- C3 ── as an admin ─────────────────────────────────────────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  INSERT INTO public.user_roles (user_id, role) VALUES (_m, 'registered_photographer');
  RESET ROLE;

  RAISE NOTICE 'PROBE PASS 6600: members cannot give or request a role or badge; an admin still can.';
END
$p$;

ROLLBACK;

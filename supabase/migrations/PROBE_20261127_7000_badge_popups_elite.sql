-- PROBE for 20261127_7000. Writes inside a transaction that is rolled back.
BEGIN;
DO $probe$
DECLARE
  _lane text := coalesce(current_setting('p32.lane', true), '(unset)');
  _admin uuid;
  _m uuid;
  _n int;
  _ok boolean;
BEGIN
  SELECT count(*) INTO _n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name IN ('badge_definitions', 'role_display_config')
     AND column_name IN ('show_label', 'popup_title', 'popup_message');
  IF _n <> 6 THEN RAISE EXCEPTION 'PROBE FAIL P1: % of 6 columns', _n; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.badge_definitions WHERE type_key = 'elite_member' AND is_active) THEN
    RAISE EXCEPTION 'PROBE FAIL P1: Elite Member badge missing';
  END IF;

  SELECT user_id INTO _admin FROM public.user_roles WHERE role = 'admin' LIMIT 1;
  SELECT p.id INTO _m FROM public.profiles p
   WHERE NOT EXISTS (SELECT 1 FROM public.user_badges b WHERE b.user_id = p.id AND b.badge_type IN ('verified', 'elite_member'))
     AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role = 'admin')
   LIMIT 1;
  IF _admin IS NULL OR _m IS NULL THEN
    RAISE NOTICE 'PROBE PASS 7000 (structure only, lane %): no admin or plain member to exercise the rules', _lane;
    RETURN;
  END IF;

  -- P2: a member cannot give themselves the gold tick
  PERFORM set_config('request.jwt.claim.sub', _m::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  _ok := false;
  BEGIN
    INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, 'elite_member', _m);
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  IF NOT _ok THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL P2: a member gave themselves Elite Member'; END IF;
  RESET ROLE;

  -- P3: an admin can; gold after blue keeps both rows (gold is drawn)
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, 'verified', _admin);
  INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, 'elite_member', _admin);
  SELECT count(*) INTO _n FROM public.user_badges WHERE user_id = _m AND badge_type IN ('verified', 'elite_member');
  IF _n <> 2 THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL P3: expected both ticks, got %', _n; END IF;

  -- P4: blue given again AFTER gold removes the gold (latest wins)
  DELETE FROM public.user_badges WHERE user_id = _m AND badge_type = 'verified';
  INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, 'verified', _admin);
  IF EXISTS (SELECT 1 FROM public.user_badges WHERE user_id = _m AND badge_type = 'elite_member') THEN
    RESET ROLE; RAISE EXCEPTION 'PROBE FAIL P4: gold stayed after blue was given later';
  END IF;
  RESET ROLE;

  RAISE NOTICE 'PROBE PASS 7000 (lane %): columns, Elite Member badge, admin-only, latest tick wins.', _lane;
END
$probe$;
ROLLBACK;

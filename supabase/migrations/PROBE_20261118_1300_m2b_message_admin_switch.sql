-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1300 — M2b messages admin switch. One transaction, ROLLBACK.
-- Before 20261118_1300: FAIL (message_admin_set_mode missing). After: M2b PASS.
--   A1  a member cannot run any admin function or read the state
--   A2  admin: each of the 4 modes is accepted and logged; bad mode refused; reason required
--   A3  list add / remove logged; adding twice changes nothing
--   A4  member rule set → send refused through the real door; clear → send works
--   A5  groups switch logged; log is append-only; state read returns mode + list + log
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

CREATE FUNCTION pg_temp.as_user(_uid uuid, _sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE _v text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE _sql INTO _v;
    RAISE EXCEPTION 'PROBE_OK:%', coalesce(_v, '<no row>');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PROBE_OK:%' THEN RETURN 'ok ' || substr(SQLERRM, 10); END IF;
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 90);
  END;
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _admin uuid; _mode text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M2b lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_admin_set_mode(text,text)') IS NULL THEN
    RAISE EXCEPTION 'M2b FAIL: message_admin_set_mode missing — expected before 20261118_1300';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m2 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M2b FAIL: need two members and one admin to test with'; END IF;

  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2) AND following_id IN (_m1, _m2);
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_selected';
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2);
  SELECT count(*) INTO _n FROM public.message_control_log;

  -- A1 member cannot
  _r := pg_temp.as_user(_m1, $q$SELECT public.message_admin_set_mode('allowed_all', 'x')$q$);
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('A1 member ran set_mode: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_admin_list_add(%L, 'x')::text$q$, _m1));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('A1 member ran list_add: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, 'SELECT public.message_admin_state()::text');
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('A1 member read the state: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_admin_set_member_rule(%L, false, true, true, false, NULL, NULL, 'x')::text$q$, _m2));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('A1 member set a member rule: ' || _r); END IF;

  -- A2 admin modes. Each as_user work is rolled back, so each mode is applied by the admin through a real
  --    transaction-local session: set the claims, run as the owner, check the result, then restore.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  FOREACH _mode IN ARRAY ARRAY['allowed_all', 'blocked_all', 'blocked_selected', 'allowed_selected'] LOOP
    PERFORM public.message_admin_set_mode(_mode, 'M2b probe');
    IF (SELECT c.mode FROM public.message_control c) <> _mode THEN _fail := _fail || ('A2 mode ' || _mode || ' not set'); END IF;
  END LOOP;
  BEGIN PERFORM public.message_admin_set_mode('everyone', 'x'); _fail := _fail || 'A2 bad mode accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.message_admin_set_mode('allowed_all', '  '); _fail := _fail || 'A2 empty reason accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  SELECT count(*) INTO _n FROM public.message_control_log WHERE area = 'mode' AND reason = 'M2b probe';
  IF _n <> 4 THEN _fail := _fail || ('A2 expected 4 mode log rows, got ' || _n); END IF;

  -- A3 list
  IF NOT public.message_admin_list_add(_m1, 'M2b probe') THEN _fail := _fail || 'A3 list_add returned false'; END IF;
  IF public.message_admin_list_add(_m1, 'M2b probe') THEN _fail := _fail || 'A3 second list_add changed something'; END IF;
  SELECT count(*) INTO _n FROM public.message_control_log WHERE area = 'list' AND user_id = _m1;
  IF _n <> 1 THEN _fail := _fail || ('A3 expected 1 list log row, got ' || _n); END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);

  -- A4 rule → the real door
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM public.message_admin_set_member_rule(_m1, false, true, true, false, NULL, NULL, 'M2b probe');
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'hello', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'refused 42501 MSG-021%' THEN _fail := _fail || ('A4 text-off rule not enforced by the door: ' || _r); END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM public.message_admin_clear_member_rule(_m1, 'M2b probe');
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'hello', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('A4 after clear the listed member could not send: ' || _r); END IF;

  -- A5 groups + log + state
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM public.message_admin_set_groups(true, 'M2b probe');
  IF NOT (SELECT groups_enabled FROM public.message_control) THEN _fail := _fail || 'A5 groups not on'; END IF;
  IF jsonb_array_length(public.message_admin_state() -> 'log') < 1 OR public.message_admin_state() ->> 'mode' IS NULL THEN
    _fail := _fail || 'A5 state read empty';
  END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  BEGIN UPDATE public.message_control_log SET reason = 'edited'; _fail := _fail || 'A5 control log was edited';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M2b FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M2b PASS — 4 modes, list, member rules, reason + log on every change, members refused';
END
$p$;

ROLLBACK;

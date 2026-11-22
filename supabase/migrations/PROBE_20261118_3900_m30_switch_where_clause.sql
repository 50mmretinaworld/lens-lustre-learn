-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3900 — M30 the three admin switches carry a WHERE. One transaction, ROLLBACK.
-- Before 20261118_3900: FAIL (a switch function updates its table with no WHERE). After: M30 PASS.
--   P1  message_admin_set_mode, message_admin_set_groups and admin_message_welcome_set each UPDATE their one-row table WITH a WHERE
--   P2  the three switches still work when run (as an admin): groups on/off, mode, welcome text — values change and are restored by the ROLLBACK
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
  _sig text; _def text; _admin uuid; _r jsonb; _g boolean; _m text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M30 lane %', current_setting('p32.lane', true);
  -- P1
  FOREACH _sig IN ARRAY ARRAY[
    'public.message_admin_set_mode(text,text)',
    'public.message_admin_set_groups(boolean,text)',
    'public.admin_message_welcome_set(boolean,text,boolean)'
  ] LOOP
    _def := pg_get_functiondef(_sig::regprocedure);
    IF _def !~ 'updated_at = now\(\) WHERE id;' THEN _fail := _fail || ('P1 ' || _sig || ' updates its table with no WHERE'); END IF;
  END LOOP;
  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M30 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  -- P2
  SELECT ur.user_id INTO _admin FROM public.user_roles ur WHERE ur.role::text = 'admin' ORDER BY ur.user_id LIMIT 1;
  IF _admin IS NULL THEN
    RAISE NOTICE 'M30 note: no admin account on this lane — P2 skipped';
  ELSE
    PERFORM pg_temp.set_user(_admin);
    SELECT groups_enabled, mode INTO _g, _m FROM public.message_control;
    PERFORM public.message_admin_set_groups(NOT _g, 'probe M30');
    IF (SELECT groups_enabled FROM public.message_control) IS NOT DISTINCT FROM _g THEN _fail := _fail || 'P2 groups switch did not change'; END IF;
    PERFORM public.message_admin_set_mode(CASE WHEN _m = 'allowed_all' THEN 'allowed_selected' ELSE 'allowed_all' END, 'probe M30');
    IF (SELECT mode FROM public.message_control) IS NOT DISTINCT FROM _m THEN _fail := _fail || 'P2 mode did not change'; END IF;
    _r := public.admin_message_welcome_set(false, 'probe M30 text', false);
    IF (SELECT body FROM public.message_welcome) <> 'probe M30 text' THEN _fail := _fail || 'P2 welcome text not saved'; END IF;
  END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M30 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M30 PASS — groups switch, mode and welcome message all carry a WHERE and still save';
END
$p$;

ROLLBACK;

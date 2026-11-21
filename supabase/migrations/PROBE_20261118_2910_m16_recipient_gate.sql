-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2910 — M16 the other member must have the chat facility. One transaction, ROLLBACK.
-- Before 20261118_2910: FAIL (message_can_reach missing); the NOTICE "P0 …" shows whether a member outside the admin list
-- could be written to. After: M16 PASS.
--   P1  switch = selected members; m1 listed, m2 NOT listed: m1 cannot reach m2 (icon hidden), a send to m2 is refused MSG-011
--   P2  m2 added to the list: m1 can reach m2 and the send works (m1 follows m2 → request)
--   P3  m2 withdrawn again (removed from the list): hidden and refused again
--   P4  yourself / nobody: false; anon cannot run message_can_reach
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
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 110);
  END;
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _m1 uuid; _m2 uuid;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M16 lane %', current_setting('p32.lane', true);

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  IF _m2 IS NULL THEN RAISE EXCEPTION 'M16 FAIL: need two members to test with'; END IF;

  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  UPDATE public.message_control SET mode = 'allowed_selected';
  DELETE FROM public.message_control_members;
  INSERT INTO public.message_control_members (user_id) VALUES (_m1);
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2) AND following_id IN (_m1, _m2);
  DELETE FROM public.user_blocks WHERE blocker_id IN (_m1, _m2) AND blocked_id IN (_m1, _m2);
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2);

  -- P0 what the old door did with a recipient who is not on the list
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'M16 hello', gen_random_uuid())::text$q$, _m2));
  RAISE NOTICE 'P0 send to a member without the chat facility: %', left(_r, 160);

  IF to_regprocedure('public.message_can_reach(uuid)') IS NULL THEN
    RAISE EXCEPTION 'M16 FAIL: message_can_reach missing — expected before 20261118_2910';
  END IF;

  -- P1
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_can_reach(%L)::text$q$, _m2));
  IF _r <> 'ok false' THEN _fail := _fail || ('P1 the icon would show for a member without the chat facility: ' || _r); END IF;
  IF _r IS NOT NULL AND (pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'M16 hello', gen_random_uuid())::text$q$, _m2))) NOT LIKE 'refused 42501 MSG-011%'
    THEN _fail := _fail || 'P1 a message to a member without the chat facility was not refused with MSG-011'; END IF;

  -- P2
  INSERT INTO public.message_control_members (user_id) VALUES (_m2);
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_can_reach(%L)::text$q$, _m2));
  IF _r <> 'ok true' THEN _fail := _fail || ('P2 a member with the chat facility cannot be reached: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT (public.message_send(%L, 'M16 hello', gen_random_uuid()) ->> 'conversation_id')$q$, _m2));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('P2 a message to a member with the chat facility was refused: ' || _r); END IF;

  -- P3
  DELETE FROM public.message_control_members WHERE user_id = _m2;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_can_reach(%L)::text$q$, _m2));
  IF _r <> 'ok false' THEN _fail := _fail || ('P3 withdrawn member still reachable: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'M16 again', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'refused 42501 MSG-011%' THEN _fail := _fail || ('P3 a withdrawn member could still be written to: ' || _r); END IF;

  -- P4
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_can_reach(%L)::text$q$, _m1));
  IF _r <> 'ok false' THEN _fail := _fail || ('P4 reaching yourself: ' || _r); END IF;
  IF has_function_privilege('anon', 'public.message_can_reach(uuid)', 'EXECUTE') THEN _fail := _fail || 'P4 anon can run message_can_reach'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M16 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M16 PASS — the chat icon and the send door both require the other member to have the chat facility';
END
$p$;

ROLLBACK;

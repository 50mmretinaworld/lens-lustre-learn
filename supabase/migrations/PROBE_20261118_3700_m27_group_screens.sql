-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3700 — M27 group chat screens. One transaction, ROLLBACK.
-- Before 20261118_3700: FAIL (message_groups_allowed_me missing). After: M27 PASS.
--   P1  groups switch OFF → not allowed; ON → allowed for a member with chat, not for one without
--   P2  the friend picker lists friends WITH the chat facility only
--   P3  a group cannot take a friend who has no chat facility (MSG-084); one with chat is taken; members read shows both + owner first
--   P4  a non-member cannot read the members; anon cannot run the three reads
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
  _ids uuid[]; _m1 uuid; _m2 uuid; _m3 uuid; _m4 uuid; _conv uuid; _r jsonb; _msg text; _b boolean;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M27 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_groups_allowed_me()') IS NULL THEN
    RAISE EXCEPTION 'M27 FAIL: message_groups_allowed_me missing — expected before 20261118_3700';
  END IF;
  SELECT array_agg(s.id) INTO _ids FROM (SELECT p.id FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 4) s;
  IF coalesce(array_length(_ids, 1), 0) < 4 THEN RAISE EXCEPTION 'M27 FAIL: need four members to test with'; END IF;
  _m1 := _ids[1]; _m2 := _ids[2]; _m3 := _ids[3]; _m4 := _ids[4];

  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  UPDATE public.message_control SET mode = 'allowed_selected', groups_enabled = false;
  DELETE FROM public.message_control_members;
  INSERT INTO public.message_control_members (user_id) VALUES (_m1), (_m2), (_m3);   -- m4 has no chat facility
  DELETE FROM public.friendships WHERE requester_id = ANY (_ids) AND addressee_id = ANY (_ids);
  DELETE FROM public.user_blocks WHERE blocker_id = ANY (_ids) AND blocked_id = ANY (_ids);
  DELETE FROM public.message_member_rules WHERE user_id = ANY (_ids);
  INSERT INTO public.friendships (requester_id, addressee_id, status) VALUES (_m1, _m2, 'accepted'), (_m1, _m3, 'accepted'), (_m1, _m4, 'accepted');

  -- P1
  PERFORM pg_temp.set_user(_m1);
  IF public.message_groups_allowed_me() THEN _fail := _fail || 'P1 groups allowed while the switch is OFF'; END IF;
  UPDATE public.message_control SET groups_enabled = true;
  IF NOT public.message_groups_allowed_me() THEN _fail := _fail || 'P1 groups not allowed for a member with chat while the switch is ON'; END IF;
  PERFORM pg_temp.set_user(_m4);
  IF public.message_groups_allowed_me() THEN _fail := _fail || 'P1 groups allowed for a member without the chat facility'; END IF;

  -- P2
  PERFORM pg_temp.set_user(_m1);
  _r := public.message_group_friends();
  IF NOT (_r::text LIKE '%' || _m2::text || '%' AND _r::text LIKE '%' || _m3::text || '%') THEN _fail := _fail || 'P2 the picker misses a friend who has chat'; END IF;
  IF _r::text LIKE '%' || _m4::text || '%' THEN _fail := _fail || 'P2 the picker lists a friend WITHOUT the chat facility'; END IF;

  -- P3
  BEGIN
    PERFORM public.message_group_create('M27 bad', ARRAY[_m2, _m3, _m4]);
    _fail := _fail || 'P3 a group took a friend without the chat facility';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS _msg = MESSAGE_TEXT;
    IF _msg NOT LIKE 'MSG-084%' THEN _fail := _fail || ('P3 wrong refusal: ' || _msg); END IF;
  END;
  -- a group needs 2..19 others: add a fifth member with chat? only m2, m3 have chat besides the owner → exactly 2 others is valid
  _conv := public.message_group_create('M27 group', ARRAY[_m2, _m3]);
  _r := public.message_group_members(_conv);
  IF jsonb_array_length(_r) <> 3 THEN _fail := _fail || ('P3 expected 3 members, got ' || jsonb_array_length(_r)); END IF;
  IF (_r -> 0 ->> 'role') <> 'owner' OR (_r -> 0 ->> 'user_id') <> _m1::text THEN _fail := _fail || 'P3 the owner should be listed first'; END IF;

  -- P4
  PERFORM pg_temp.set_user(_m4);
  BEGIN
    PERFORM public.message_group_members(_conv);
    _fail := _fail || 'P4 a non-member read the group members';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF has_function_privilege('anon', 'public.message_groups_allowed_me()', 'EXECUTE') OR has_function_privilege('anon', 'public.message_group_friends()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.message_group_members(uuid)', 'EXECUTE') THEN _fail := _fail || 'P4 a visitor can run a group read'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M27 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M27 PASS — group screens read the right members; a group can only take friends who have the chat facility';
END
$p$;

ROLLBACK;

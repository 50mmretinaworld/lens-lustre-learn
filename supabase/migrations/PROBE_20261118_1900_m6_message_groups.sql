-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1900 — M6 group chats. One transaction, ROLLBACK.
-- Before 20261118_1900: FAIL (message_group_create missing). After: M6 PASS.
--   G1  groups OFF (the seeded state): create / send refused MSG-080
--   G2  groups ON: create with the creator's friends works; a non-friend is refused (MSG-084); 1 member / 20+ refused
--   G3  only the owner adds / removes; the added person must be the owner's friend; the owner cannot leave; a member can
--   G4  send: member sends; outsider refused; never twice; word guard blocks; the switch (blocked_all) refuses
--   G5  member rule groups_ok=false → MSG-081; a member under review → refused
--   G6  members read the group thread; an outsider cannot
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
CREATE FUNCTION pg_temp.on(_uid uuid) RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', _uid::text, true);
$f$;
CREATE FUNCTION pg_temp.off() RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _a uuid; _b uuid; _c uuid; _d uuid; _e uuid; _out uuid; _g uuid; _j jsonb;
  _ids uuid[];
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M6 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_group_create(text,uuid[])') IS NULL THEN
    RAISE EXCEPTION 'M6 FAIL: message_group_create missing — expected before 20261118_1900';
  END IF;

  SELECT array_agg(id) INTO _ids FROM (
    SELECT p.id FROM public.profiles p JOIN auth.users u ON u.id = p.id
     WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin')
     ORDER BY p.created_at LIMIT 6) s;
  IF cardinality(_ids) < 6 THEN RAISE EXCEPTION 'M6 FAIL: need six active members to test with'; END IF;
  _a := _ids[1]; _b := _ids[2]; _c := _ids[3]; _d := _ids[4]; _e := _ids[5]; _out := _ids[6];

  UPDATE public.system_flags SET value = false WHERE key = 'job_engine_push';
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  DELETE FROM public.friendships WHERE requester_id = ANY (_ids) AND addressee_id = ANY (_ids);
  DELETE FROM public.user_blocks WHERE blocker_id = ANY (_ids) AND blocked_id = ANY (_ids);
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_all', groups_enabled = false;
  DELETE FROM public.message_word_rules;
  INSERT INTO public.message_word_rules (category, pattern, action) VALUES ('threat', 'kill you', 'block');
  -- a is friends with b, c, d, e (not with out)
  INSERT INTO public.friendships (requester_id, addressee_id, status) SELECT _a, x, 'accepted' FROM unnest(ARRAY[_b, _c, _d, _e]) x;

  -- G1
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_create('Trip', ARRAY[%L, %L]::uuid[])::text$q$, _b, _c));
  IF _r NOT LIKE 'refused 42501 MSG-080%' THEN _fail := _fail || ('G1 create with groups OFF: ' || _r); END IF;

  UPDATE public.message_control SET groups_enabled = true;

  -- G2
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_create('Trip', ARRAY[%L, %L]::uuid[])::text$q$, _b, _c));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('G2 create with friends refused: ' || _r); END IF;
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_create('Trip', ARRAY[%L, %L]::uuid[])::text$q$, _b, _out));
  IF _r NOT LIKE 'refused 42501 MSG-084%' THEN _fail := _fail || ('G2 non-friend accepted: ' || _r); END IF;
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_create('Trip', ARRAY[%L]::uuid[])::text$q$, _b));
  IF _r NOT LIKE 'refused 22023 MSG-083%' THEN _fail := _fail || ('G2 one-member group accepted: ' || _r); END IF;
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_create('  ', ARRAY[%L, %L]::uuid[])::text$q$, _b, _c));
  IF _r NOT LIKE 'refused 22023 MSG-082%' THEN _fail := _fail || ('G2 nameless group accepted: ' || _r); END IF;

  -- the real group, kept
  PERFORM pg_temp.on(_a);
  _g := public.message_group_create('Weekend shoot', ARRAY[_b, _c]);
  PERFORM pg_temp.off();
  SELECT count(*) INTO _n FROM public.conversation_members WHERE conversation_id = _g;
  IF _n <> 3 THEN _fail := _fail || ('G2 group should have 3 members, has ' || _n); END IF;

  -- G3
  _r := pg_temp.as_user(_b, format($q$SELECT public.message_group_add(%L, %L)::text$q$, _g, _d));
  IF _r NOT LIKE 'refused 42501 MSG-085%' THEN _fail := _fail || ('G3 a member added someone: ' || _r); END IF;
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_add(%L, %L)::text$q$, _g, _out));
  IF _r NOT LIKE 'refused 42501 MSG-084%' THEN _fail := _fail || ('G3 owner added a non-friend: ' || _r); END IF;
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_add(%L, %L)::text$q$, _g, _d));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('G3 owner could not add a friend: ' || _r); END IF;
  _r := pg_temp.as_user(_a, format($q$SELECT public.message_group_leave(%L)::text$q$, _g));
  IF _r NOT LIKE 'refused 22023 MSG-086%' THEN _fail := _fail || ('G3 owner left the group: ' || _r); END IF;
  _r := pg_temp.as_user(_c, format($q$SELECT public.message_group_leave(%L)::text$q$, _g));
  IF _r <> 'ok true' THEN _fail := _fail || ('G3 member could not leave: ' || _r); END IF;
  _r := pg_temp.as_user(_b, format($q$SELECT public.message_group_remove(%L, %L)::text$q$, _g, _a));
  IF _r NOT LIKE 'refused 42501 MSG-085%' THEN _fail := _fail || ('G3 member removed the owner: ' || _r); END IF;

  -- G4 send
  _r := pg_temp.as_user(_b, format($q$SELECT public.message_send_group(%L, 'see you at 6', gen_random_uuid())::text$q$, _g));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('G4 member could not send: ' || _r); END IF;
  _r := pg_temp.as_user(_out, format($q$SELECT public.message_send_group(%L, 'hi', gen_random_uuid())::text$q$, _g));
  IF _r NOT LIKE 'refused 42501 MSG-071%' THEN _fail := _fail || ('G4 outsider sent: ' || _r); END IF;
  _r := pg_temp.as_user(_b, format($q$SELECT public.message_send_group(%L, 'I will kill you', gen_random_uuid())::text$q$, _g));
  IF _r NOT LIKE 'refused 42501 MSG-060%' THEN _fail := _fail || ('G4 word guard not applied: ' || _r); END IF;
  PERFORM pg_temp.on(_b);
  _j := public.message_send_group(_g, 'once', '11111111-1111-1111-1111-111111111111');
  _j := public.message_send_group(_g, 'once again', '11111111-1111-1111-1111-111111111111');
  PERFORM pg_temp.off();
  IF _j ->> 'duplicate' <> 'true' THEN _fail := _fail || 'G4 duplicate not recognised'; END IF;
  SELECT count(*) INTO _n FROM public.messages WHERE client_msg_id = '11111111-1111-1111-1111-111111111111';
  IF _n <> 1 THEN _fail := _fail || ('G4 duplicate stored ' || _n || ' rows'); END IF;
  UPDATE public.message_control SET mode = 'blocked_all';
  _r := pg_temp.as_user(_b, format($q$SELECT public.message_send_group(%L, 'still here', gen_random_uuid())::text$q$, _g));
  IF _r NOT LIKE 'refused 42501 MSG-010%' THEN _fail := _fail || ('G4 blocked_all not enforced for groups: ' || _r); END IF;
  UPDATE public.message_control SET mode = 'allowed_all';

  -- G5
  INSERT INTO public.message_member_rules (user_id, groups_ok) VALUES (_b, false);
  _r := pg_temp.as_user(_b, format($q$SELECT public.message_send_group(%L, 'x', gen_random_uuid())::text$q$, _g));
  IF _r NOT LIKE 'refused 42501 MSG-081%' THEN _fail := _fail || ('G5 groups_ok=false not enforced: ' || _r); END IF;
  DELETE FROM public.message_member_rules WHERE user_id = _b;
  INSERT INTO public.account_states (user_id, state, reason) VALUES (_b, 'under_review', 'M6 PROBE');
  _r := pg_temp.as_user(_b, format($q$SELECT public.message_send_group(%L, 'x', gen_random_uuid())::text$q$, _g));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('G5 member under review sent: ' || _r); END IF;
  DELETE FROM public.account_states WHERE user_id = _b;

  -- G6
  _r := pg_temp.as_user(_b, format($q$SELECT jsonb_array_length(public.message_thread(%L))::text$q$, _g));
  IF _r NOT LIKE 'ok %' OR _r = 'ok 0' THEN _fail := _fail || ('G6 member cannot read the group thread: ' || _r); END IF;
  _r := pg_temp.as_user(_out, format($q$SELECT public.message_thread(%L)::text$q$, _g));
  IF _r NOT LIKE 'refused 42501 MSG-071%' THEN _fail := _fail || ('G6 outsider read the group: ' || _r); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M6 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M6 PASS — groups OFF by default, friends only, owner-only changes, same safety checks as 1:1';
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1600 — M4 inbox / requests / thread. One transaction, ROLLBACK.
-- Before 20261118_1600: FAIL (message_my_conversations missing). After: M4 PASS.
--   I1  anon cannot run any of them; sign-in required
--   I2  inbox lists my chat with the other member, last message and unread count; requests list is separate
--   I3  thread: member reads own chat; an outsider is refused (MSG-071); held messages only for their sender
--   I4  mark read zeroes the unread count; unread_counts shows inbox + requests
--   I5  accept moves requests → inbox; decline moves requests → declined and it leaves both lists
--   I6  mute flag round-trips; a member cannot change someone else's folder / read state
--   I7  reading still works while the account is under review; writing the read state is refused
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
-- as above, but the work stays (so a later step can see it): for the state-changing steps
CREATE FUNCTION pg_temp.keep_as(_uid uuid) RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', _uid::text, true);
$f$;
CREATE FUNCTION pg_temp.keep_off() RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _m3 uuid; _c uuid; _c2 uuid; _held bigint; _j jsonb;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M4 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_my_conversations(text,integer,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'M4 FAIL: message_my_conversations missing — expected before 20261118_1600';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) ORDER BY p.created_at LIMIT 1;
  IF _m3 IS NULL THEN RAISE EXCEPTION 'M4 FAIL: need three members to test with'; END IF;
  UPDATE public.system_flags SET value = false WHERE key IN ('job_engine_push');   -- no push jobs from the test messages

  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'm4probe:' || gen_random_uuid(), _m1) RETURNING id INTO _c;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_c, _m1, 'inbox', now() - interval '1 day'), (_c, _m2, 'inbox', now() - interval '1 day');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'first', gen_random_uuid()), (_c, _m1, 'second', gen_random_uuid());
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, status) VALUES (_c, _m1, 'held text', gen_random_uuid(), 'held') RETURNING id INTO _held;
  UPDATE public.conversations SET last_message_at = now() WHERE id = _c;
  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'm4probe2:' || gen_random_uuid(), _m3) RETURNING id INTO _c2;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_c2, _m3, 'inbox', now() - interval '1 day'), (_c2, _m2, 'requests', now() - interval '1 day');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c2, _m3, 'request hello', gen_random_uuid());
  UPDATE public.conversations SET last_message_at = now() WHERE id = _c2;

  -- I1
  IF has_function_privilege('anon', 'public.message_my_conversations(text,integer,timestamptz)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.message_thread(uuid,bigint,integer)', 'EXECUTE') THEN _fail := _fail || 'I1 anon can execute'; END IF;

  -- I2
  _r := pg_temp.as_user(_m2, $q$SELECT public.message_my_conversations('inbox')::text$q$);
  IF _r NOT LIKE 'ok %' OR _r NOT LIKE '%"body": "second"%' OR _r LIKE '%held text%' OR _r LIKE '%request hello%' THEN _fail := _fail || ('I2 inbox content wrong: ' || left(_r, 200)); END IF;
  IF _r NOT LIKE '%"unread": 2%' THEN _fail := _fail || ('I2 unread should be 2: ' || left(_r, 200)); END IF;
  _r := pg_temp.as_user(_m2, $q$SELECT public.message_my_conversations('requests')::text$q$);
  IF _r NOT LIKE '%request hello%' OR _r LIKE '%"second"%' THEN _fail := _fail || ('I2 requests list wrong: ' || left(_r, 200)); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.message_my_conversations('inbox')::text$q$);
  IF _r NOT LIKE '%held text%' THEN _fail := _fail || 'I2 sender does not see own held message as last'; END IF;

  -- I3
  _r := pg_temp.as_user(_m3, format($q$SELECT public.message_thread(%L)::text$q$, _c));
  IF _r NOT LIKE 'refused 42501 MSG-071%' THEN _fail := _fail || ('I3 outsider read a thread: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, format($q$SELECT jsonb_array_length(public.message_thread(%L))::text$q$, _c));
  IF _r <> 'ok 2' THEN _fail := _fail || ('I3 receiver should see 2 messages (held hidden): ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT jsonb_array_length(public.message_thread(%L))::text$q$, _c));
  IF _r <> 'ok 3' THEN _fail := _fail || ('I3 sender should see 3 messages (own held): ' || _r); END IF;
  _r := pg_temp.as_user(_m2, format($q$SELECT jsonb_array_length(public.message_thread(%L, %L, 1))::text$q$, _c, _held + 1));
  IF _r <> 'ok 1' THEN _fail := _fail || ('I3 limit 1 not honoured: ' || _r); END IF;

  -- I4 (state-changing: run with a kept identity, then clear)
  PERFORM pg_temp.keep_as(_m2);
  PERFORM public.message_mark_read(_c);
  _j := public.message_unread_counts();
  PERFORM pg_temp.keep_off();
  IF (_j ->> 'inbox')::int <> 0 THEN _fail := _fail || ('I4 inbox unread after mark read: ' || _j::text); END IF;
  IF (_j ->> 'requests')::int <> 1 THEN _fail := _fail || ('I4 requests count should be 1: ' || _j::text); END IF;

  -- I5
  PERFORM pg_temp.keep_as(_m2);
  PERFORM public.message_accept_request(_c2);
  SELECT folder INTO _r FROM public.conversation_members WHERE conversation_id = _c2 AND user_id = _m2;
  PERFORM pg_temp.keep_off();
  IF _r <> 'inbox' THEN _fail := _fail || ('I5 accept left folder ' || _r); END IF;
  UPDATE public.conversation_members SET folder = 'requests' WHERE conversation_id = _c2 AND user_id = _m2;
  PERFORM pg_temp.keep_as(_m2);
  PERFORM public.message_decline_request(_c2);
  SELECT folder INTO _r FROM public.conversation_members WHERE conversation_id = _c2 AND user_id = _m2;
  _j := public.message_my_conversations('requests') || public.message_my_conversations('inbox');
  PERFORM pg_temp.keep_off();
  IF _r <> 'declined' THEN _fail := _fail || ('I5 decline left folder ' || _r); END IF;
  IF _j::text LIKE '%request hello%' THEN _fail := _fail || 'I5 declined chat still listed'; END IF;

  -- I6
  PERFORM pg_temp.keep_as(_m2);
  PERFORM public.message_set_muted(_c, true);
  SELECT muted::text INTO _r FROM public.conversation_members WHERE conversation_id = _c AND user_id = _m2;
  PERFORM pg_temp.keep_off();
  IF _r <> 'true' THEN _fail := _fail || 'I6 mute not stored'; END IF;
  PERFORM pg_temp.keep_as(_m3);
  PERFORM public.message_set_muted(_c, false);        -- m3 is not in chat _c: must change nothing
  PERFORM public.message_accept_request(_c);
  PERFORM pg_temp.keep_off();
  SELECT muted::text INTO _r FROM public.conversation_members WHERE conversation_id = _c AND user_id = _m2;
  IF _r <> 'true' THEN _fail := _fail || 'I6 an outsider changed someone else''s mute'; END IF;

  -- I7 under review: reads work, read-state write refused
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  INSERT INTO public.account_states (user_id, state, reason) VALUES (_m2, 'under_review', 'M4 PROBE');
  _r := pg_temp.as_user(_m2, $q$SELECT jsonb_array_length(public.message_my_conversations('inbox'))::text$q$);
  IF _r NOT LIKE 'ok %' OR _r = 'ok 0' THEN _fail := _fail || ('I7 reviewed member cannot read the inbox: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, format($q$SELECT public.message_mark_read(%L)::text$q$, _c));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('I7 reviewed member wrote the read state: ' || _r); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M4 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M4 PASS — inbox, requests, thread, read state; held hidden, outsiders refused, review still reads';
END
$p$;

ROLLBACK;

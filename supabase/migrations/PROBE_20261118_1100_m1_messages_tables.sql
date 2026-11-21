-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1100 — M1 messages tables. One transaction, ROLLBACK:
-- the planted chats, members and states are thrown away.
-- Before 20261118_1100: FAIL (conversations missing). After: M1 PASS.
--   T1  all 11 tables exist with row security on
--   T2  API rights: anon none anywhere; authenticated SELECT only on 4 tables, no write on any
--   T3  seed: mode allowed_selected, groups OFF, selected list EMPTY (nobody may send yet)
--   T4  a member cannot insert a message / chat / member row directly
--   T5  a member reads only chats they belong to (member, member-of-other-chat, outsider)
--   T6  a held message is invisible to the other member, visible to its sender
--   T7  no unsend: a signed-in edit or delete of a message is refused; held → sent review
--       allowed; the service path (no signed-in actor) may delete
--   T8  logs are append-only; same client_msg_id twice is refused; direct chat key unique
--   T9  the account guard is on the 4 chat tables: a member under review cannot write (switch ON)
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
    IF _sql ~* '^\s*(insert|update|delete)' AND _sql !~* 'returning' THEN
      EXECUTE _sql; _v := 'written';
    ELSE
      EXECUTE _sql INTO _v;
    END IF;
    RAISE EXCEPTION 'PROBE_OK:%', coalesce(_v, '<no row>');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PROBE_OK:%' THEN RETURN 'ok ' || substr(SQLERRM, 10); END IF;
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 80);
  END;
END
$f$;

-- run a statement as the database owner but with a signed-in actor (auth.uid() set)
CREATE FUNCTION pg_temp.as_actor(_uid uuid, _sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
    EXECUTE _sql;
    RAISE EXCEPTION 'PROBE_OK:written';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PROBE_OK:%' THEN RETURN 'ok'; END IF;
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 80);
  END;
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _m3 uuid;
  _c1 uuid := gen_random_uuid(); _c2 uuid := gen_random_uuid();
  _msg bigint; _held bigint;
  _tables text[] := ARRAY['message_control', 'message_control_members', 'message_member_rules', 'message_control_log',
    'conversations', 'conversation_members', 'messages', 'message_attachments',
    'message_word_rules', 'message_guard_events', 'message_admin_reads'];
  t text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M1 lane %', current_setting('p32.lane', true);
  IF to_regclass('public.conversations') IS NULL OR to_regclass('public.messages') IS NULL THEN
    RAISE EXCEPTION 'M1 FAIL: messages tables missing — expected before 20261118_1100';
  END IF;

  -- T1
  FOREACH t IN ARRAY _tables LOOP
    SELECT count(*) INTO _n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = t AND c.relrowsecurity;
    IF _n <> 1 THEN _fail := _fail || ('T1 ' || t || ' missing or row security off'); END IF;
  END LOOP;

  -- T2
  FOREACH t IN ARRAY _tables LOOP
    IF has_table_privilege('anon', 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE') THEN
      _fail := _fail || ('T2 anon has a right on ' || t);
    END IF;
    IF has_table_privilege('authenticated', 'public.' || t, 'INSERT') OR has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       OR has_table_privilege('authenticated', 'public.' || t, 'DELETE') THEN
      _fail := _fail || ('T2 authenticated can write ' || t);
    END IF;
    IF has_table_privilege('authenticated', 'public.' || t, 'SELECT') <> (t IN ('conversations', 'conversation_members', 'messages', 'message_attachments')) THEN
      _fail := _fail || ('T2 authenticated SELECT wrong on ' || t);
    END IF;
  END LOOP;

  -- T3
  IF NOT EXISTS (SELECT 1 FROM public.message_control WHERE mode = 'allowed_selected' AND NOT groups_enabled) THEN
    _fail := _fail || 'T3 message_control seed is not allowed_selected / groups OFF';
  END IF;
  SELECT count(*) INTO _n FROM public.message_control_members;
  RAISE NOTICE 'M1 T3 selected list rows=% (expected 0 until M2b)', _n;

  -- members to test with
  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) ORDER BY p.created_at LIMIT 1;
  IF _m1 IS NULL OR _m2 IS NULL OR _m3 IS NULL THEN RAISE EXCEPTION 'M1 FAIL: need three active members to test with'; END IF;

  -- plant (service path: no signed-in actor)
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  INSERT INTO public.conversations (id, kind, direct_key, created_by)
  VALUES (_c1, 'direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m1),
         (_c2, 'direct', 'probe:' || _c2::text, _m3);
  INSERT INTO public.conversation_members (conversation_id, user_id) VALUES (_c1, _m1), (_c1, _m2), (_c2, _m3);
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id)
  VALUES (_c1, _m1, 'hello', gen_random_uuid()) RETURNING id INTO _msg;
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, status)
  VALUES (_c1, _m1, 'held one', gen_random_uuid(), 'held') RETURNING id INTO _held;

  -- T4
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (%L, %L, 'x', gen_random_uuid())$q$, _c1, _m1));
  IF _r LIKE 'ok%' THEN _fail := _fail || 'T4 member inserted a message directly'; END IF;
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO public.conversation_members (conversation_id, user_id) VALUES (%L, %L)$q$, _c2, _m1));
  IF _r LIKE 'ok%' THEN _fail := _fail || 'T4 member added themselves to a chat'; END IF;
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'x:y', %L)$q$, _m1));
  IF _r LIKE 'ok%' THEN _fail := _fail || 'T4 member inserted a conversation directly'; END IF;

  -- T5
  _r := pg_temp.as_user(_m1, format($q$SELECT count(*)::text FROM public.messages WHERE conversation_id IN (%L, %L) AND status = 'sent'$q$, _c1, _c2));
  IF _r <> 'ok 1' THEN _fail := _fail || ('T5 member m1 sees ' || _r || ' sent messages, expected 1'); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT count(*)::text FROM public.messages WHERE conversation_id = %L$q$, _c1));
  IF _r <> 'ok 0' THEN _fail := _fail || ('T5 outsider m3 reads another chat: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT count(*)::text FROM public.conversations WHERE id = %L$q$, _c1));
  IF _r <> 'ok 0' THEN _fail := _fail || ('T5 outsider m3 sees another conversation: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, format($q$SELECT count(*)::text FROM public.conversation_members WHERE conversation_id = %L$q$, _c1));
  IF _r <> 'ok 1' THEN _fail := _fail || ('T5 m2 should see only their own member row, got ' || _r); END IF;

  -- T6
  _r := pg_temp.as_user(_m2, format($q$SELECT count(*)::text FROM public.messages WHERE id = %L$q$, _held));
  IF _r <> 'ok 0' THEN _fail := _fail || ('T6 receiver sees a held message: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT count(*)::text FROM public.messages WHERE id = %L$q$, _held));
  IF _r <> 'ok 1' THEN _fail := _fail || ('T6 sender does not see own held message: ' || _r); END IF;

  -- T7
  _r := pg_temp.as_actor(_m1, format($q$UPDATE public.messages SET body = 'edited' WHERE id = %L$q$, _msg));
  IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('T7 signed-in edit not refused: ' || _r); END IF;
  _r := pg_temp.as_actor(_m1, format($q$DELETE FROM public.messages WHERE id = %L$q$, _msg));
  IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('T7 signed-in delete not refused: ' || _r); END IF;
  _r := pg_temp.as_actor(_m1, format($q$UPDATE public.messages SET status = 'sent' WHERE id = %L$q$, _held));
  IF _r NOT LIKE 'ok%' THEN _fail := _fail || ('T7 held → sent review refused: ' || _r); END IF;
  _r := pg_temp.as_actor(_m1, format($q$UPDATE public.messages SET body = 'x', status = 'sent' WHERE id = %L$q$, _held));
  IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('T7 body edit during review not refused: ' || _r); END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  BEGIN
    DELETE FROM public.messages WHERE id = _held;
  EXCEPTION WHEN OTHERS THEN _fail := _fail || ('T7 service-path delete refused: ' || SQLERRM);
  END;

  -- T8
  INSERT INTO public.message_control_log (actor_id, area, old_value, new_value, reason) VALUES (_m1, 'mode', 'a', 'b', 'M1 probe');
  BEGIN
    UPDATE public.message_control_log SET reason = 'changed';
    _fail := _fail || 'T8 control log was edited';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.message_admin_reads (admin_id, conversation_id, reason) VALUES (_m1, _c1, 'M1 probe');
    DELETE FROM public.message_admin_reads;
    _fail := _fail || 'T8 admin-read log row was deleted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id)
    SELECT conversation_id, sender_id, 'again', client_msg_id FROM public.messages WHERE id = _msg;
    _fail := _fail || 'T8 same client_msg_id accepted twice';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.conversations (kind, direct_key, created_by)
    SELECT 'direct', direct_key, _m1 FROM public.conversations WHERE id = _c1;
    _fail := _fail || 'T8 second direct chat for the same pair accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- T9
  SELECT count(*) INTO _n FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
   WHERE tg.tgname = 'zz_account_state_guard' AND c.relname IN ('conversations', 'conversation_members', 'messages', 'message_attachments');
  IF _n <> 4 THEN _fail := _fail || ('T9 guard attached to ' || _n || ' of 4 chat tables'); END IF;
  INSERT INTO public.account_states (user_id, state, reason) VALUES (_m1, 'under_review', 'M1 PROBE');
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  _r := pg_temp.as_actor(_m1, format($q$INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (%L, %L, 'blocked', gen_random_uuid())$q$, _c1, _m1));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('T9 member under review could write a message: ' || _r); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M1 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M1 PASS — messages tables closed by default, no unsend, logs append-only, account guard on';
END
$p$;

ROLLBACK;

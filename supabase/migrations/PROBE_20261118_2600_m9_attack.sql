-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2600 — M9 attack tests on the private messages. One transaction, ROLLBACK. No migration.
-- Always runnable (it only needs M1–M13 applied). PASS = every attack below is refused.
--   A1  signed-out (anon) and PUBLIC can run none of the message / broadcast / admin-view functions
--   A2  signed-in members cannot run the internal functions (send core, batch job, tick helper, push trigger)
--   A3  a member cannot write any message table directly (insert / update / delete) and cannot read the admin tables
--   A4  a member outside a chat cannot read it: thread, rows, photos, mark-read, delivered mark
--   A5  an oversized, empty or id-less message is refused by the send door; a forged sender cannot be named
--   A6  a normal member cannot use any admin function (an account under review is covered by PROBE 1200)
--   A7  a hidden-code message body is only ever stored and returned as plain text
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '90s';
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
  _r text; _n int; _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _conv uuid; _msg bigint; _oid oid; _name text;
  _internal text[] := ARRAY['message_send_core(uuid,text,uuid,jsonb)', 'message_broadcast_run_batch(jsonb)', 'message_broadcast_roll_up(bigint)',
                            'message_broadcast_withdraw_run(jsonb)', 'message_tick(uuid,uuid,timestamp with time zone)', 'messages_push()'];
  _tables text[] := ARRAY['message_control', 'message_control_members', 'message_member_rules', 'message_control_log', 'message_word_rules',
                          'message_guard_events', 'message_admin_reads', 'message_files_purge', 'message_reports',
                          'message_broadcasts', 'message_broadcast_batches', 'message_broadcast_recipients'];
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M9 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_tick(uuid,uuid,timestamptz)') IS NULL OR to_regclass('public.message_broadcasts') IS NULL THEN
    RAISE EXCEPTION 'M9 FAIL: M12 / M13 are not applied — apply 2300 and 2400 first';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m3 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M9 FAIL: need three members and one admin to test with'; END IF;

  -- a chat between m1 and m2 holding a message with hidden code and a picture; m3 is outside it
  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_conv, _m1, 'inbox', now() - interval '1 hour'), (_conv, _m2, 'inbox', now() - interval '1 hour');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at)
    VALUES (_conv, _m1, '<script>alert(1)</script><img src=x onerror=alert(2)> javascript:alert(3)', gen_random_uuid(), now() - interval '5 minutes') RETURNING id INTO _msg;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes) VALUES (_msg, _m1::text || '/m9-probe.webp', 'image/webp', 1000);

  -- A1 anon / PUBLIC can run nothing
  FOR _oid, _name IN
    SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND (p.proname LIKE 'message\_%' OR p.proname LIKE 'admin\_message\_%' OR p.proname LIKE 'admin\_view\_%' OR p.proname = 'messages_push')
  LOOP
    IF has_function_privilege('anon', _oid, 'EXECUTE') THEN _fail := _fail || ('A1 anon can run ' || _name); END IF;
  END LOOP;

  -- A2 internal functions are not for members
  FOREACH _name IN ARRAY _internal LOOP
    _oid := to_regprocedure('public.' || _name);
    IF _oid IS NULL THEN _fail := _fail || ('A2 missing ' || _name); CONTINUE; END IF;
    IF has_function_privilege('authenticated', _oid, 'EXECUTE') OR has_function_privilege('anon', _oid, 'EXECUTE') THEN _fail := _fail || ('A2 a member can run ' || _name); END IF;
  END LOOP;

  -- A3 no direct writes, no reading of admin tables
  FOREACH _name IN ARRAY ARRAY['messages', 'conversations', 'conversation_members', 'message_attachments'] LOOP
    IF has_table_privilege('authenticated', 'public.' || _name, 'INSERT') OR has_table_privilege('authenticated', 'public.' || _name, 'UPDATE')
       OR has_table_privilege('authenticated', 'public.' || _name, 'DELETE') OR has_table_privilege('anon', 'public.' || _name, 'SELECT') THEN
      _fail := _fail || ('A3 a member or anon has a direct right on ' || _name);
    END IF;
  END LOOP;
  FOREACH _name IN ARRAY _tables LOOP
    IF has_table_privilege('authenticated', 'public.' || _name, 'SELECT') OR has_table_privilege('authenticated', 'public.' || _name, 'INSERT')
       OR has_table_privilege('anon', 'public.' || _name, 'SELECT') THEN
      _fail := _fail || ('A3 a member or anon can reach table ' || _name);
    END IF;
  END LOOP;
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (%L, %L, 'forged', gen_random_uuid())::text$q$, _conv, _m2));
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('A3 a forged-sender insert went through: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$DELETE FROM public.messages WHERE id = %s$q$, _msg));
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('A3 a member deleted a message: ' || _r); END IF;

  -- A4 a member outside the chat
  _r := pg_temp.as_user(_m3, format($q$SELECT public.message_thread(%L)::text$q$, _conv));
  IF _r NOT LIKE 'refused 42501 MSG-071%' THEN _fail := _fail || ('A4 an outsider read the thread: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT count(*)::text FROM public.messages WHERE conversation_id = %L$q$, _conv));
  IF _r <> 'ok 0' THEN _fail := _fail || ('A4 an outsider saw message rows: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT count(*)::text FROM public.message_attachments WHERE message_id = %s$q$, _msg));
  IF _r <> 'ok 0' THEN _fail := _fail || ('A4 an outsider saw attachment rows: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT public.message_photo_visible(%L)::text$q$, _m1::text || '/m9-probe.webp'));
  IF _r <> 'ok false' THEN _fail := _fail || ('A4 an outsider can open the picture: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT public.message_mark_read(%L)::text$q$, _conv));
  IF _r <> 'ok false' THEN _fail := _fail || ('A4 an outsider marked the chat read: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, $q$SELECT public.message_my_conversations('inbox', 100, NULL)::text$q$);
  IF _r LIKE '%' || _conv::text || '%' THEN _fail := _fail || 'A4 the chat shows in an outsider''s inbox'; END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT public.admin_view_thread(%L, %L)::text$q$, _m1, _conv));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('A4 a member used the admin thread view: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT public.admin_view_inbox(%L)::text$q$, _m1));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('A4 a member used the admin inbox view: ' || _r); END IF;
  UPDATE public.conversation_members SET last_read_at = NULL, last_delivered_at = NULL WHERE conversation_id = _conv;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m3, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _m3::text, true);
  PERFORM public.message_mark_delivered();
  IF EXISTS (SELECT 1 FROM public.conversation_members WHERE conversation_id = _conv AND last_delivered_at IS NOT NULL) THEN
    _fail := _fail || 'A4 an outsider''s delivered mark touched someone else''s chat';
  END IF;

  -- A5 the send door
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, repeat('x', 4001), gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'refused 22023 MSG-003%' THEN _fail := _fail || ('A5 a 4001-character message was not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, '   ', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'refused 22023 MSG-003%' THEN _fail := _fail || ('A5 an empty message was not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'hi', NULL)::text$q$, _m2));
  IF _r NOT LIKE 'refused 22023 MSG-003%' THEN _fail := _fail || ('A5 a message without an id was not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'hi', gen_random_uuid())::text$q$, _m1));
  IF _r NOT LIKE 'refused 22023 MSG-002%' THEN _fail := _fail || ('A5 a message to yourself was not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send_photo(%L, 'c', gen_random_uuid(), '[]'::jsonb)::text$q$, _m2));
  -- any refusal will do: the closed switch (MSG-010) or the photo rule (MSG-024) both stop it
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('A5 a photo message with no photos was not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'hi', gen_random_uuid(), %L)::text$q$, _m2, _m3));
  IF _r NOT LIKE 'refused 42883%' THEN _fail := _fail || ('A5 message_send accepts a sender argument: ' || _r); END IF;

  -- A6 a member under review cannot send; admin functions refuse a normal member
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_broadcasts(NULL, 10, 0)::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGBC-001%' THEN _fail := _fail || ('A6 a member listed broadcasts: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.message_admin_set_mode('allowed_all', 'attack')::text$q$);
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('A6 a member changed the messaging mode: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_word_rules()::text$q$);
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('A6 a member read the word list: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_member_search(NULL, 'all', 'name', 'asc', 5, 0)::text$q$);
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('A6 a member searched the member table: ' || _r); END IF;

  -- A7 hidden code stays text: stored verbatim, returned as a plain JSON string, never reshaped
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m2, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _m2::text, true);
  _r := (public.message_thread(_conv) -> 0 ->> 'body');
  IF _r IS DISTINCT FROM '<script>alert(1)</script><img src=x onerror=alert(2)> javascript:alert(3)' THEN _fail := _fail || ('A7 the body was changed in transit: ' || coalesce(left(_r, 60), 'null')); END IF;
  IF jsonb_typeof(public.message_thread(_conv) -> 0 -> 'body') <> 'string' THEN _fail := _fail || 'A7 the body is not a plain string'; END IF;

  SELECT count(*) INTO _n FROM public.message_control_log WHERE reason = 'attack';
  IF _n > 0 THEN _fail := _fail || 'A6 an attack left a control-log row'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M9 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M9 PASS — anon blocked, internals closed, no direct writes, outsiders see nothing, bad messages refused, admin functions closed to members, hidden code stays text';
END
$p$;

ROLLBACK;

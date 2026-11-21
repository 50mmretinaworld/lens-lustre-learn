-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3800 — M29 chat export + closed unused admin functions. One transaction, ROLLBACK.
-- Before 20261118_3800: FAIL (admin_message_export missing). After: M29 PASS.
--   P1  an admin exports a chat: members, every message in order, the photo list; one view row is recorded per export
--   P2  a member cannot export (MSGADM-001); a member who is not in the chat is refused for the admin too (MSG-071)
--   P3  the four unused admin functions cannot be run by members or visitors; anon cannot run the export
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
  _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _conv uuid; _msg bigint; _r jsonb; _n int; r record;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M29 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.admin_message_export(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'M29 FAIL: admin_message_export missing — expected before 20261118_3800';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT rr.user_id INTO _admin FROM public.user_roles rr JOIN auth.users u ON u.id = rr.user_id WHERE rr.role::text = 'admin' ORDER BY rr.user_id LIMIT 1;
  IF _m3 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M29 FAIL: need three members and one admin to test with'; END IF;

  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text) || ':m29', _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_conv, _m1, 'inbox', now() - interval '2 hours'), (_conv, _m2, 'inbox', now() - interval '2 hours');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at) VALUES (_conv, _m1, 'M29 one', gen_random_uuid(), now() - interval '90 minutes');
  INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id, created_at) VALUES (_conv, _m2, 'photo', '', gen_random_uuid(), now() - interval '80 minutes') RETURNING id INTO _msg;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes, width, height) VALUES (_msg, _m2::text || '/m29.webp', 'image/webp', 1000, 10, 10);

  -- P1
  PERFORM pg_temp.set_user(_admin);
  _r := public.admin_message_export(_m1, _conv);
  IF jsonb_array_length(_r -> 'members') <> 2 THEN _fail := _fail || ('P1 expected 2 members, got ' || jsonb_array_length(_r -> 'members')); END IF;
  IF jsonb_array_length(_r -> 'messages') <> 2 OR (_r ->> 'message_count')::int <> 2 THEN _fail := _fail || 'P1 expected 2 messages'; END IF;
  IF (_r -> 'messages' -> 0 ->> 'body') <> 'M29 one' THEN _fail := _fail || 'P1 messages are not in order'; END IF;
  IF jsonb_array_length(_r -> 'messages' -> 1 -> 'photos') <> 1 THEN _fail := _fail || 'P1 the photo is missing from the export'; END IF;
  PERFORM public.admin_message_export(_m1, _conv);
  SELECT count(*) INTO _n FROM public.message_admin_views WHERE admin_id = _admin AND conversation_id = _conv;
  IF _n <> 2 THEN _fail := _fail || ('P1 two exports should leave two view rows, found ' || _n); END IF;

  -- P2
  PERFORM pg_temp.set_user(_m1);
  BEGIN
    PERFORM public.admin_message_export(_m1, _conv);
    _fail := _fail || 'P2 a member exported a chat';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.set_user(_admin);
  BEGIN
    PERFORM public.admin_message_export(_m3, _conv);
    _fail := _fail || 'P2 an export was made for a member who is not in the chat';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- P3
  FOR r IN SELECT p.oid, p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('admin_message_member_chats', 'admin_read_conversation', 'admin_message_held_queue', 'admin_message_review') LOOP
    IF has_function_privilege('authenticated', r.oid, 'EXECUTE') OR has_function_privilege('anon', r.oid, 'EXECUTE') THEN _fail := _fail || ('P3 ' || r.sig::text || ' can still be run by members or visitors'); END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.admin_message_export(uuid,uuid)', 'EXECUTE') THEN _fail := _fail || 'P3 anon can run the export'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M29 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M29 PASS — admins can export a chat (recorded); members cannot; four unused admin functions are closed';
END
$p$;

ROLLBACK;

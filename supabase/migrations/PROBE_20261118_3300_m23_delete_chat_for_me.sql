-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3300 — M23 delete chat for me. One transaction, ROLLBACK.
-- Before 20261118_3300: FAIL (message_clear_chat missing). After: M23 PASS.
--   P1  before clearing: the chat is in m1's list and its thread has 2 messages
--   P2  m1 clears: thread empty, chat gone from m1's list; m2 still sees both messages and the chat
--   P3  a new message after clearing: m1's thread shows only the new one, the chat is back in the list
--   P4  a non-member cannot clear someone else's chat (nothing changes); anon cannot run it
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
  _m1 uuid; _m2 uuid; _m3 uuid; _conv uuid; _n int; _inlist boolean;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M23 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_clear_chat(uuid)') IS NULL THEN
    RAISE EXCEPTION 'M23 FAIL: message_clear_chat missing — expected before 20261118_3300';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  IF _m3 IS NULL THEN RAISE EXCEPTION 'M23 FAIL: need three members to test with'; END IF;

  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text) || ':m23', _m1, now() - interval '20 minutes') RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_conv, _m1, 'inbox', now() - interval '3 hours'), (_conv, _m2, 'inbox', now() - interval '3 hours');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at) VALUES
    (_conv, _m1, 'M23 one', gen_random_uuid(), now() - interval '2 hours'), (_conv, _m2, 'M23 two', gen_random_uuid(), now() - interval '90 minutes');

  -- P1
  PERFORM pg_temp.set_user(_m1);
  _n := jsonb_array_length(public.message_thread(_conv));
  IF _n <> 2 THEN _fail := _fail || ('P1 thread should have 2 messages before clearing, has ' || _n); END IF;
  _inlist := public.message_my_conversations('inbox', 100, NULL)::text LIKE '%' || _conv::text || '%';
  IF NOT _inlist THEN _fail := _fail || 'P1 the chat is not in the list before clearing'; END IF;

  -- P4 (first: a stranger clears nothing)
  PERFORM pg_temp.set_user(_m3);
  IF public.message_clear_chat(_conv) THEN _fail := _fail || 'P4 a non-member cleared a chat'; END IF;

  -- P2
  PERFORM pg_temp.set_user(_m1);
  IF NOT public.message_clear_chat(_conv) THEN _fail := _fail || 'P2 the member could not clear the chat'; END IF;
  _n := jsonb_array_length(public.message_thread(_conv));
  IF _n <> 0 THEN _fail := _fail || ('P2 thread should be empty after clearing, has ' || _n); END IF;
  IF public.message_my_conversations('inbox', 100, NULL)::text LIKE '%' || _conv::text || '%' THEN _fail := _fail || 'P2 the cleared chat is still in the list'; END IF;
  PERFORM pg_temp.set_user(_m2);
  _n := jsonb_array_length(public.message_thread(_conv));
  IF _n <> 2 THEN _fail := _fail || ('P2 the OTHER member lost messages: ' || _n); END IF;
  IF NOT (public.message_my_conversations('inbox', 100, NULL)::text LIKE '%' || _conv::text || '%') THEN _fail := _fail || 'P2 the other member lost the chat'; END IF;

  -- P3
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at) VALUES (_conv, _m2, 'M23 three', gen_random_uuid(), now() + interval '1 minute');
  UPDATE public.conversations SET last_message_at = now() + interval '1 minute' WHERE id = _conv;
  PERFORM pg_temp.set_user(_m1);
  _n := jsonb_array_length(public.message_thread(_conv));
  IF _n <> 1 THEN _fail := _fail || ('P3 after a new message the thread should show only it, shows ' || _n); END IF;
  IF NOT (public.message_my_conversations('inbox', 100, NULL)::text LIKE '%' || _conv::text || '%') THEN _fail := _fail || 'P3 the chat did not come back after a new message'; END IF;

  IF has_function_privilege('anon', 'public.message_clear_chat(uuid)', 'EXECUTE') THEN _fail := _fail || 'P4 anon can run message_clear_chat'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M23 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M23 PASS — a member can clear a chat from their side only; the other side is untouched; a new message brings it back with just the new messages';
END
$p$;

ROLLBACK;

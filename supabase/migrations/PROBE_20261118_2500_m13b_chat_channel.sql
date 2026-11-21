-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2500 — M13b live chat channel. One transaction, ROLLBACK.
-- Before 20261118_2500: FAIL (message_channel_member missing). After: M13b PASS.
--   C1  a member of a chat may use its channel; a member outside it may not; a declined chat may not
--   C2  a malformed topic, an empty topic, signed-out and anon are all refused (no error, just false)
--   C3  both policies exist on realtime.messages, for authenticated only, broadcast only
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
  _m1 uuid; _m2 uuid; _m3 uuid; _conv uuid; _n int; _anon boolean;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M13b lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_channel_member(text)') IS NULL THEN
    RAISE EXCEPTION 'M13b FAIL: message_channel_member missing — expected before 20261118_2500';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  IF _m3 IS NULL THEN RAISE EXCEPTION 'M13b FAIL: need three members to test with'; END IF;

  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder) VALUES (_conv, _m1, 'inbox'), (_conv, _m2, 'inbox');

  -- C1
  PERFORM pg_temp.set_user(_m1);
  IF NOT public.message_channel_member('chat:' || _conv::text) THEN _fail := _fail || 'C1a a member was refused his own chat channel'; END IF;
  PERFORM pg_temp.set_user(_m2);
  IF NOT public.message_channel_member('chat:' || _conv::text) THEN _fail := _fail || 'C1b the other member was refused'; END IF;
  PERFORM pg_temp.set_user(_m3);
  IF public.message_channel_member('chat:' || _conv::text) THEN _fail := _fail || 'C1c a member OUTSIDE the chat got in'; END IF;
  UPDATE public.conversation_members SET folder = 'declined' WHERE conversation_id = _conv AND user_id = _m2;
  PERFORM pg_temp.set_user(_m2);
  IF public.message_channel_member('chat:' || _conv::text) THEN _fail := _fail || 'C1d a declined chat still opens its channel'; END IF;

  -- C2
  PERFORM pg_temp.set_user(_m1);
  IF public.message_channel_member('chat:not-a-uuid') OR public.message_channel_member('') OR public.message_channel_member(NULL)
     OR public.message_channel_member(_conv::text) OR public.message_channel_member('room:' || _conv::text)
     OR public.message_channel_member('chat:' || upper(_conv::text)) THEN
    _fail := _fail || 'C2a a malformed topic was accepted';
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  _anon := public.message_channel_member('chat:' || _conv::text);
  IF _anon THEN _fail := _fail || 'C2b a signed-out caller got in'; END IF;

  -- C3
  SELECT count(*) INTO _n FROM pg_policies
   WHERE schemaname = 'realtime' AND tablename = 'messages' AND policyname IN ('messages_chat_channel_read', 'messages_chat_channel_write')
     AND roles = '{authenticated}' AND coalesce(qual, with_check) LIKE '%broadcast%' AND coalesce(qual, with_check) LIKE '%message_channel_member%';
  IF _n <> 2 THEN _fail := _fail || ('C3 expected the 2 channel policies on realtime.messages, found ' || _n); END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M13b FAIL: %', array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M13b PASS — only the chat''s members may use chat:<id>; malformed / signed-out refused; 2 policies in place';
END
$p$;

ROLLBACK;

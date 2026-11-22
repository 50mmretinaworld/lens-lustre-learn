-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_4200 — M32 official account. One transaction, ROLLBACK.
-- Before 20261118_4200: FAIL (message_m32_backup / triggers missing). After: M32 PASS.
--   O1  both triggers are in place; members cannot call their functions
--   O2  a member who only follows the official account writes first → the chat is in Chats on BOTH sides (not Requests)
--   O3  moving a chat with the official account to Requests / Declined (any path) leaves it in Chats, both sides;
--       a chat between two members still goes to Requests as before
--   O4  a member cannot block the official account (refused); a member can still block another member;
--       the official account can still block a member
--   O5  no chat row with the official account is outside Chats; no block names it
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
  _ids uuid[]; _m1 uuid; _m2 uuid; _admin uuid; _r jsonb; _conv uuid; _f text; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M32 lane %', current_setting('p32.lane', true);
  IF to_regclass('public.message_m32_backup') IS NULL THEN
    RAISE EXCEPTION 'M32 FAIL: message_m32_backup missing — expected before 20261118_4200';
  END IF;

  -- O1
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'conversation_members_official_folder' AND tgrelid = 'public.conversation_members'::regclass AND tgenabled <> 'D') THEN
    _fail := _fail || 'O1 folder trigger missing or disabled';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'user_blocks_official_guard' AND tgrelid = 'public.user_blocks'::regclass AND tgenabled <> 'D') THEN
    _fail := _fail || 'O1 block trigger missing or disabled';
  END IF;
  IF has_function_privilege('authenticated', 'public.message_official_folder()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.user_blocks_official_guard()', 'EXECUTE') THEN
    _fail := _fail || 'O1 members can call a trigger function';
  END IF;

  -- set-up: two members, the official (admin) account, all allowed to message, no links between them
  SELECT array_agg(s.id) INTO _ids FROM (SELECT p.id FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 2) s;
  IF coalesce(array_length(_ids, 1), 0) < 2 THEN RAISE EXCEPTION 'M32 FAIL: need two members to test with'; END IF;
  _m1 := _ids[1]; _m2 := _ids[2];
  SELECT rr.user_id INTO _admin FROM public.user_roles rr JOIN auth.users u ON u.id = rr.user_id WHERE rr.role::text = 'admin' ORDER BY rr.user_id LIMIT 1;
  IF _admin IS NULL THEN RAISE EXCEPTION 'M32 FAIL: need the official (admin) account to test with'; END IF;
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  UPDATE public.message_control SET mode = 'allowed_selected' WHERE id;
  DELETE FROM public.message_control_members WHERE user_id IS NOT NULL;
  INSERT INTO public.message_control_members (user_id) VALUES (_m1), (_m2), (_admin);
  DELETE FROM public.message_member_rules WHERE user_id IN (_m1, _m2, _admin);
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2, _admin) AND following_id IN (_m1, _m2, _admin);
  DELETE FROM public.friendships WHERE requester_id IN (_m1, _m2, _admin) AND addressee_id IN (_m1, _m2, _admin);
  DELETE FROM public.user_blocks WHERE blocker_id IN (_m1, _m2, _admin) AND blocked_id IN (_m1, _m2, _admin);
  DELETE FROM public.conversations WHERE direct_key IN (
    least(_m1::text, _admin::text) || ':' || greatest(_m1::text, _admin::text),
    least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text));
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _admin), (_m1, _m2);   -- follow only, no follow back

  -- O2
  PERFORM pg_temp.set_user(_m1);
  _r := public.message_send(_admin, 'probe M32 hello official', gen_random_uuid());
  _conv := (_r ->> 'conversation_id')::uuid;
  SELECT folder INTO _f FROM public.conversation_members WHERE conversation_id = _conv AND user_id = _admin;
  IF _f IS DISTINCT FROM 'inbox' THEN _fail := _fail || ('O2 official account got the member''s first message in ' || coalesce(_f, '<no row>')); END IF;
  SELECT folder INTO _f FROM public.conversation_members WHERE conversation_id = _conv AND user_id = _m1;
  IF _f IS DISTINCT FROM 'inbox' THEN _fail := _fail || ('O2 member''s own row in ' || coalesce(_f, '<no row>')); END IF;
  PERFORM pg_temp.set_user(_admin);
  PERFORM public.message_send(_m1, 'probe M32 reply', gen_random_uuid());
  IF EXISTS (SELECT 1 FROM public.conversation_members WHERE conversation_id = _conv AND folder <> 'inbox') THEN
    _fail := _fail || 'O2 a row left Chats after the official reply';
  END IF;

  -- O3
  UPDATE public.conversation_members SET folder = 'requests' WHERE conversation_id = _conv AND user_id = _admin;
  UPDATE public.conversation_members SET folder = 'declined' WHERE conversation_id = _conv AND user_id = _m1;
  IF EXISTS (SELECT 1 FROM public.conversation_members WHERE conversation_id = _conv AND folder <> 'inbox') THEN
    _fail := _fail || 'O3 a chat with the official account was moved out of Chats';
  END IF;
  PERFORM pg_temp.set_user(_m1);
  _r := public.message_send(_m2, 'probe M32 member to member', gen_random_uuid());
  IF _r ->> 'folder' IS DISTINCT FROM 'requests'
     OR NOT EXISTS (SELECT 1 FROM public.conversation_members WHERE conversation_id = (_r ->> 'conversation_id')::uuid AND user_id = _m2 AND folder = 'requests') THEN
    _fail := _fail || ('O3 member-to-member follow-only chat no longer goes to Requests: ' || _r::text);
  END IF;

  -- O4
  BEGIN
    INSERT INTO public.user_blocks (blocker_id, blocked_id) VALUES (_m1, _admin);
    _fail := _fail || 'O4 a member blocked the official account';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.user_blocks (blocker_id, blocked_id) VALUES (_m1, _m2);
  EXCEPTION WHEN OTHERS THEN
    _fail := _fail || ('O4 a member can no longer block another member: ' || SQLERRM);
  END;
  BEGIN
    INSERT INTO public.user_blocks (blocker_id, blocked_id) VALUES (_admin, _m2);
  EXCEPTION WHEN OTHERS THEN
    _fail := _fail || ('O4 the official account can no longer block a member: ' || SQLERRM);
  END;

  -- O5
  SELECT count(*) INTO _n FROM public.conversation_members cm
   WHERE cm.folder <> 'inbox'
     AND (public.has_role(cm.user_id, 'admin'::public.app_role)
          OR EXISTS (SELECT 1 FROM public.conversation_members o JOIN public.conversations c ON c.id = o.conversation_id
                      WHERE o.conversation_id = cm.conversation_id AND o.user_id <> cm.user_id
                        AND c.kind = 'direct' AND public.has_role(o.user_id, 'admin'::public.app_role)));
  IF _n > 0 THEN _fail := _fail || (_n || ' O5 chat row(s) with the official account outside Chats'); END IF;
  SELECT count(*) INTO _n FROM public.user_blocks b WHERE public.has_role(b.blocked_id, 'admin'::public.app_role);
  IF _n > 0 THEN _fail := _fail || (_n || ' O5 block(s) naming the official account'); END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M32 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M32 PASS — chats with 50mm Retina World stay in Chats on both sides; it cannot be blocked; member chats unchanged';
END
$p$;

ROLLBACK;

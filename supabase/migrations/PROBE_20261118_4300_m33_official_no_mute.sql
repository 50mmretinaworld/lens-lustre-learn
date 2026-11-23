-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_4300 — M33 official account cannot be muted / its chat not deleted. One transaction, ROLLBACK.
-- Before 20261118_4300: FAIL (message_m33_backup missing). After: M33 PASS.
--   N1  both guards in place; members cannot call the guard functions
--   N2  a member cannot mute, and cannot "Delete chat for me", the chat with the official account; un-mute still works
--   N3  a member cannot mute the official account's posts
--   N4  member-to-member: mute, delete chat and post mute still work as before
--   N5  no member row of an official chat is muted or cleared; no post mute names the official account
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
  _ids uuid[]; _m1 uuid; _m2 uuid; _admin uuid; _r jsonb; _conv uuid; _conv2 uuid; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M33 lane %', current_setting('p32.lane', true);
  IF to_regclass('public.message_m33_backup') IS NULL THEN
    RAISE EXCEPTION 'M33 FAIL: message_m33_backup missing — expected before 20261118_4300';
  END IF;

  -- N1
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'conversation_members_official_chat_guard' AND tgrelid = 'public.conversation_members'::regclass AND tgenabled <> 'D') THEN
    _fail := _fail || 'N1 chat guard missing or disabled';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'feed_muted_authors_official_guard' AND tgrelid = 'public.feed_muted_authors'::regclass AND tgenabled <> 'D') THEN
    _fail := _fail || 'N1 post-mute guard missing or disabled';
  END IF;
  IF has_function_privilege('authenticated', 'public.message_is_member_official_chat(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.message_official_chat_guard()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.feed_muted_authors_official_guard()', 'EXECUTE') THEN
    _fail := _fail || 'N1 members can call a guard function';
  END IF;

  -- set-up
  SELECT array_agg(s.id) INTO _ids FROM (SELECT p.id FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 2) s;
  IF coalesce(array_length(_ids, 1), 0) < 2 THEN RAISE EXCEPTION 'M33 FAIL: need two members to test with'; END IF;
  _m1 := _ids[1]; _m2 := _ids[2];
  SELECT rr.user_id INTO _admin FROM public.user_roles rr JOIN auth.users u ON u.id = rr.user_id WHERE rr.role::text = 'admin' ORDER BY rr.user_id LIMIT 1;
  IF _admin IS NULL THEN RAISE EXCEPTION 'M33 FAIL: need the official (admin) account to test with'; END IF;
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  UPDATE public.message_control SET mode = 'allowed_selected' WHERE id;
  DELETE FROM public.message_control_members WHERE user_id IS NOT NULL;
  INSERT INTO public.message_control_members (user_id) VALUES (_m1), (_m2), (_admin);
  DELETE FROM public.message_member_rules WHERE user_id IN (_m1, _m2, _admin);
  DELETE FROM public.user_blocks WHERE blocker_id IN (_m1, _m2, _admin) AND blocked_id IN (_m1, _m2, _admin);
  DELETE FROM public.feed_muted_authors WHERE user_id IN (_m1, _m2) AND author_id IN (_m1, _m2);
  DELETE FROM public.conversations WHERE direct_key IN (
    least(_m1::text, _admin::text) || ':' || greatest(_m1::text, _admin::text),
    least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text));
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2) ON CONFLICT DO NOTHING;
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m2, _m1) ON CONFLICT DO NOTHING;

  PERFORM pg_temp.set_user(_admin);
  _r := public.message_send(_m1, 'probe M33 from the official account', gen_random_uuid());
  _conv := (_r ->> 'conversation_id')::uuid;
  PERFORM pg_temp.set_user(_m1);
  _r := public.message_send(_m2, 'probe M33 member to member', gen_random_uuid());
  _conv2 := (_r ->> 'conversation_id')::uuid;

  -- N2
  BEGIN
    PERFORM public.message_set_muted(_conv, true);
    _fail := _fail || 'N2 a member muted the chat with the official account';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.message_clear_chat(_conv);
    _fail := _fail || 'N2 a member deleted the chat with the official account';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.message_set_muted(_conv, false);
  EXCEPTION WHEN OTHERS THEN
    _fail := _fail || ('N2 un-mute refused: ' || SQLERRM);
  END;

  -- N3
  BEGIN
    INSERT INTO public.feed_muted_authors (user_id, author_id) VALUES (_m1, _admin);
    _fail := _fail || 'N3 a member muted the official account''s posts';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- N4
  BEGIN
    PERFORM public.message_set_muted(_conv2, true);
    PERFORM public.message_clear_chat(_conv2);
    INSERT INTO public.feed_muted_authors (user_id, author_id) VALUES (_m1, _m2);
  EXCEPTION WHEN OTHERS THEN
    _fail := _fail || ('N4 member-to-member mute / delete / post mute refused: ' || SQLERRM);
  END;
  IF NOT EXISTS (SELECT 1 FROM public.conversation_members WHERE conversation_id = _conv2 AND user_id = _m1 AND muted AND cleared_at IS NOT NULL) THEN
    _fail := _fail || 'N4 member-to-member mute / delete did not take effect';
  END IF;

  -- N5
  SELECT count(*) INTO _n FROM public.conversation_members cm
   WHERE (cm.muted OR cm.cleared_at IS NOT NULL) AND public.message_is_member_official_chat(cm.conversation_id, cm.user_id);
  IF _n > 0 THEN _fail := _fail || (_n || ' N5 member row(s) of an official chat muted or cleared'); END IF;
  SELECT count(*) INTO _n FROM public.feed_muted_authors f WHERE public.has_role(f.author_id, 'admin'::public.app_role);
  IF _n > 0 THEN _fail := _fail || (_n || ' N5 post mute(s) of the official account'); END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M33 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M33 PASS — the official chat cannot be muted or deleted, its posts cannot be muted; member-to-member unchanged';
END
$p$;

ROLLBACK;

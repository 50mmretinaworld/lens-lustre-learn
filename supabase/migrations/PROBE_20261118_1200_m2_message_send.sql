-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1200 — M2 message_send. One transaction, ROLLBACK.
-- Before 20261118_1200: FAIL (message_send missing). After: M2 PASS.
--   S1  anon cannot run it; signed-in only
--   S2  switch: allowed_selected + empty list refuses; listed member sends; blocked_selected; blocked_all; allowed_all
--   S3  relationship: no link refused; follow only → receiver's Requests; mutual follow → inbox; friend → inbox
--   S4  blocks either direction refused
--   S5  sender under review refused; receiver under review refused
--   S6  member rules: timed block, text off, friends-only refused
--   S7  input: empty, too long, no message id refused; same client_msg_id twice = one row
--   S8  limits: 20 in a minute, daily limit, official account exempt
--   S9  official (admin) account reaches anyone, inbox; the receiver can then read it
--   S10 sender is auth.uid(): a member cannot send as someone else (no sender argument)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';
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

CREATE FUNCTION pg_temp.send(_from uuid, _to uuid, _body text, _id uuid DEFAULT gen_random_uuid()) RETURNS text LANGUAGE sql AS $f$
  SELECT pg_temp.as_user(_from, format('SELECT public.message_send(%L, %L, %L)::text', _to, _body, _id));
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _m3 uuid; _m4 uuid; _admin uuid; _id uuid := gen_random_uuid();
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M2 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_send(uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'M2 FAIL: message_send missing — expected before 20261118_1200';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m4 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2, _m3) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' AND r.user_id NOT IN (_m1, _m2, _m3, _m4) LIMIT 1;
  IF _m4 IS NULL THEN RAISE EXCEPTION 'M2 FAIL: need four active non-admin members to test with'; END IF;

  -- clean slate between the test members (service path), switch seeded closed
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2, _m3, _m4) AND following_id IN (_m1, _m2, _m3, _m4);
  DELETE FROM public.friendships WHERE requester_id IN (_m1, _m2, _m3, _m4) AND addressee_id IN (_m1, _m2, _m3, _m4);
  DELETE FROM public.user_blocks WHERE blocker_id IN (_m1, _m2, _m3, _m4) AND blocked_id IN (_m1, _m2, _m3, _m4);
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_selected';
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2);          -- m1 follows m2 (no follow back)
  -- chats planted by the service path (the as_user sends below roll their own work back)
  INSERT INTO public.conversations (kind, direct_key, created_by)
  VALUES ('direct', least(_m3::text, _m4::text) || ':' || greatest(_m3::text, _m4::text), _m3);
  INSERT INTO public.conversation_members (conversation_id, user_id, role, folder)
  SELECT c.id, u, 'member', 'inbox' FROM public.conversations c, unnest(ARRAY[_m3, _m4]) u
   WHERE c.direct_key = least(_m3::text, _m4::text) || ':' || greatest(_m3::text, _m4::text);
  IF _admin IS NOT NULL THEN
    INSERT INTO public.conversations (kind, direct_key, created_by)
    VALUES ('direct', least(_admin::text, _m4::text) || ':' || greatest(_admin::text, _m4::text), _admin);
    INSERT INTO public.conversation_members (conversation_id, user_id, role, folder)
    SELECT c.id, u, 'member', 'inbox' FROM public.conversations c, unnest(ARRAY[_admin, _m4]) u
     WHERE c.direct_key = least(_admin::text, _m4::text) || ':' || greatest(_admin::text, _m4::text);
  END IF;

  -- S1
  IF has_function_privilege('anon', 'public.message_send(uuid,text,uuid)', 'EXECUTE') THEN _fail := _fail || 'S1 anon can execute message_send'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.message_send(uuid,text,uuid)', 'EXECUTE') THEN _fail := _fail || 'S1 authenticated cannot execute message_send'; END IF;

  -- S2 switch
  _r := pg_temp.send(_m1, _m2, 'hi');
  IF _r NOT LIKE 'refused 42501 MSG-010%' THEN _fail := _fail || ('S2 empty selected list should refuse: ' || _r); END IF;
  INSERT INTO public.message_control_members (user_id) VALUES (_m1);
  _r := pg_temp.send(_m1, _m2, 'hi');
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('S2 listed member refused: ' || _r); END IF;
  _r := pg_temp.send(_m3, _m1, 'hi');
  IF _r NOT LIKE 'refused 42501 MSG-010%' THEN _fail := _fail || ('S2 unlisted member allowed: ' || _r); END IF;
  UPDATE public.message_control SET mode = 'blocked_selected';
  _r := pg_temp.send(_m1, _m2, 'hi');
  IF _r NOT LIKE 'refused 42501 MSG-010%' THEN _fail := _fail || ('S2 blocked_selected: listed member allowed: ' || _r); END IF;
  _r := pg_temp.send(_m3, _m1, 'hi');                       -- m3 not listed, no link → passes the switch, fails on relationship
  IF _r NOT LIKE 'refused 42501 MSG-040%' THEN _fail := _fail || ('S2 blocked_selected: unlisted member did not pass the switch: ' || _r); END IF;
  UPDATE public.message_control SET mode = 'blocked_all';
  _r := pg_temp.send(_m1, _m2, 'hi');
  IF _r NOT LIKE 'refused 42501 MSG-010%' THEN _fail := _fail || ('S2 blocked_all allowed: ' || _r); END IF;
  UPDATE public.message_control SET mode = 'allowed_all';
  _r := pg_temp.send(_m1, _m2, 'hi');
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('S2 allowed_all refused: ' || _r); END IF;

  -- S3 relationship (mode allowed_all now)
  _r := pg_temp.send(_m3, _m1, 'hi');
  IF _r NOT LIKE 'refused 42501 MSG-040%' THEN _fail := _fail || ('S3 no link not refused: ' || _r); END IF;
  _r := pg_temp.send(_m1, _m2, 'follow only', gen_random_uuid());
  IF _r NOT LIKE '%"folder": "requests"%' THEN _fail := _fail || ('S3 follow-only should land in requests: ' || _r); END IF;
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m3, _m4), (_m4, _m3);   -- mutual follow
  _r := pg_temp.send(_m3, _m4, 'mutual');
  IF _r NOT LIKE '%"folder": "inbox"%' THEN _fail := _fail || ('S3 mutual follow should land in inbox: ' || _r); END IF;
  INSERT INTO public.friendships (requester_id, addressee_id, status) VALUES (_m2, _m3, 'accepted');
  _r := pg_temp.send(_m2, _m3, 'friend');
  IF _r NOT LIKE '%"folder": "inbox"%' THEN _fail := _fail || ('S3 friend should land in inbox: ' || _r); END IF;

  -- S4 blocks both ways
  INSERT INTO public.user_blocks (blocker_id, blocked_id) VALUES (_m3, _m2);
  _r := pg_temp.send(_m2, _m3, 'x');
  IF _r NOT LIKE 'refused 42501 MSG-030%' THEN _fail := _fail || ('S4 blocked receiver: sender not refused: ' || _r); END IF;
  _r := pg_temp.send(_m3, _m2, 'x');
  IF _r NOT LIKE 'refused 42501 MSG-030%' THEN _fail := _fail || ('S4 blocker sending to blocked not refused: ' || _r); END IF;
  DELETE FROM public.user_blocks WHERE blocker_id = _m3 AND blocked_id = _m2;

  -- S5 under review
  INSERT INTO public.account_states (user_id, state, reason) VALUES (_m3, 'under_review', 'M2 PROBE');
  _r := pg_temp.send(_m3, _m4, 'x');
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('S5 sender under review not refused: ' || _r); END IF;
  _r := pg_temp.send(_m4, _m3, 'x');
  IF _r NOT LIKE 'refused 42501 MSG-011%' THEN _fail := _fail || ('S5 receiver under review not refused: ' || _r); END IF;
  DELETE FROM public.account_states WHERE user_id = _m3;

  -- S6 member rules
  INSERT INTO public.message_member_rules (user_id, blocked_until) VALUES (_m4, now() + interval '1 day');
  _r := pg_temp.send(_m4, _m3, 'x');
  IF _r NOT LIKE 'refused 42501 MSG-020%' THEN _fail := _fail || ('S6 timed block not refused: ' || _r); END IF;
  UPDATE public.message_member_rules SET blocked_until = now() - interval '1 day' WHERE user_id = _m4;
  _r := pg_temp.send(_m4, _m3, 'after the block');
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('S6 expired block still refused: ' || _r); END IF;
  UPDATE public.message_member_rules SET text_ok = false WHERE user_id = _m4;
  _r := pg_temp.send(_m4, _m3, 'x');
  IF _r NOT LIKE 'refused 42501 MSG-021%' THEN _fail := _fail || ('S6 text off not refused: ' || _r); END IF;
  UPDATE public.message_member_rules SET text_ok = true, friends_only = true WHERE user_id = _m4;
  _r := pg_temp.send(_m4, _m3, 'x');           -- mutual follow, not a friend
  IF _r NOT LIKE 'refused 42501 MSG-022%' THEN _fail := _fail || ('S6 friends-only not refused: ' || _r); END IF;
  DELETE FROM public.message_member_rules WHERE user_id = _m4;

  -- S7 input + never twice
  _r := pg_temp.send(_m3, _m4, '   ');
  IF _r NOT LIKE 'refused 22023 MSG-003%' THEN _fail := _fail || ('S7 empty body not refused: ' || _r); END IF;
  _r := pg_temp.send(_m3, _m4, repeat('a', 4001));
  IF _r NOT LIKE 'refused 22023 MSG-003%' THEN _fail := _fail || ('S7 oversize body not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT public.message_send(%L, 'x', NULL)::text$q$, _m4));
  IF _r NOT LIKE 'refused 22023 MSG-003%' THEN _fail := _fail || ('S7 missing message id not refused: ' || _r); END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id)
  SELECT c.id, _m3, 'planted', _id FROM public.conversations c WHERE c.direct_key = least(_m3::text, _m4::text) || ':' || greatest(_m3::text, _m4::text);
  _r := pg_temp.send(_m3, _m4, 'planted again', _id);
  IF _r NOT LIKE '%"duplicate": true%' THEN _fail := _fail || ('S7 same client_msg_id not recognised: ' || _r); END IF;
  SELECT count(*) INTO _n FROM public.messages WHERE sender_id = _m3 AND client_msg_id = _id;
  IF _n <> 1 THEN _fail := _fail || ('S7 duplicate wrote ' || _n || ' rows'); END IF;

  -- S8 limits
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id)
  SELECT c.id, _m3, 'burst ' || g, gen_random_uuid()
    FROM public.conversations c, generate_series(1, 20) g
   WHERE c.direct_key = least(_m3::text, _m4::text) || ':' || greatest(_m3::text, _m4::text);
  _r := pg_temp.send(_m3, _m4, 'one too many');
  IF _r NOT LIKE 'refused 42501 MSG-050%' THEN _fail := _fail || ('S8 21st message in a minute not refused: ' || _r); END IF;
  UPDATE public.messages SET created_at = created_at - interval '2 hours' WHERE sender_id = _m3;   -- service path: age them past the minute
  INSERT INTO public.message_member_rules (user_id, daily_limit) VALUES (_m3, 1);
  _r := pg_temp.send(_m3, _m4, 'over the daily limit');
  IF _r NOT LIKE 'refused 42501 MSG-051%' THEN _fail := _fail || ('S8 daily limit not enforced: ' || _r); END IF;
  DELETE FROM public.message_member_rules WHERE user_id = _m3;

  -- S9 official account
  IF _admin IS NOT NULL THEN
    _r := pg_temp.send(_admin, _m4, 'welcome from 50mm');
    IF _r NOT LIKE '%"folder": "inbox"%' THEN _fail := _fail || ('S9 official account to a stranger: ' || _r); END IF;
    PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
    INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id)
    SELECT c.id, _admin, 'burst ' || g, gen_random_uuid()
      FROM public.conversations c, generate_series(1, 25) g
     WHERE c.direct_key = least(_admin::text, _m4::text) || ':' || greatest(_admin::text, _m4::text);
    _r := pg_temp.send(_admin, _m4, 'still allowed');
    IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('S9 official account hit a limit: ' || _r); END IF;
    UPDATE public.conversation_members SET folder = 'inbox' WHERE user_id = _m4;
    _r := pg_temp.as_user(_m4, format($q$SELECT count(*)::text FROM public.messages WHERE sender_id = %L$q$, _admin));
    IF _r NOT LIKE 'ok %' OR _r = 'ok 0' THEN _fail := _fail || ('S9 receiver cannot read the official message: ' || _r); END IF;
  ELSE
    RAISE NOTICE 'M2 S9 skipped: no admin account on this lane';
  END IF;

  -- S10 sender is auth.uid()
  _r := pg_temp.send(_m4, _m3, 'who am i');
  IF _r LIKE 'ok %' THEN
    SELECT count(*) INTO _n FROM public.messages WHERE body = 'who am i' AND sender_id <> _m4;
    IF _n <> 0 THEN _fail := _fail || 'S10 a message was stored with a different sender'; END IF;
  END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M2 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M2 PASS — one send door: switch, relationship, blocks, review, member rules, limits, never twice';
END
$p$;

ROLLBACK;

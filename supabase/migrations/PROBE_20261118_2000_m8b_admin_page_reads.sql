-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2000 — M8b admin page reads. One transaction, ROLLBACK.
-- Before 20261118_2000: FAIL (admin_message_word_rules missing). After: M8B PASS.
--   B1  a member cannot read the word list or a member's chat list
--   B2  admin reads the word list (the seeded starter rules are there)
--   B3  admin chat list: needs a reason, is logged first, shows chats + counts, never message text
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

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _admin uuid; _res jsonb;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M8B lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.admin_message_word_rules()') IS NULL THEN
    RAISE EXCEPTION 'M8B FAIL: admin_message_word_rules missing — expected before 20261118_2000';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m2 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M8B FAIL: need two members and one admin to test with'; END IF;

  -- a chat with one message to look up
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2) AND following_id IN (_m1, _m2);
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_selected';
  INSERT INTO public.message_control_members (user_id) VALUES (_m1);
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2);
  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m1);
  INSERT INTO public.conversation_members (conversation_id, user_id, role)
    SELECT c.id, x.u, 'member' FROM public.conversations c, (VALUES (_m1), (_m2)) x(u)
     WHERE c.direct_key = least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text);
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id)
    SELECT c.id, _m1, 'M8B secret text', gen_random_uuid() FROM public.conversations c
     WHERE c.direct_key = least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text);

  -- B1 member cannot
  _r := pg_temp.as_user(_m1, 'SELECT public.admin_message_word_rules()::text');
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('B1 member read the word list: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.admin_message_member_chats(%L, 'x')::text$q$, _m2));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('B1 member read a chat list: ' || _r); END IF;

  -- B2 admin word list
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  _res := public.admin_message_word_rules();
  IF jsonb_typeof(_res) <> 'array' OR jsonb_array_length(_res) < 1 THEN _fail := _fail || 'B2 word list empty'; END IF;

  -- B3 chat list: reason needed, logged, no text
  BEGIN PERFORM public.admin_message_member_chats(_m1, '  '); _fail := _fail || 'B3 empty reason accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  SELECT count(*) INTO _n FROM public.message_control_log WHERE area = 'lookup';
  IF _n <> 0 THEN _fail := _fail || 'B3 a refused look-up was logged'; END IF;
  _res := public.admin_message_member_chats(_m1, 'M8B probe');
  SELECT count(*) INTO _n FROM public.message_control_log WHERE area = 'lookup' AND user_id = _m1 AND reason = 'M8B probe';
  IF _n <> 1 THEN _fail := _fail || ('B3 expected 1 look-up log row, got ' || _n); END IF;
  IF jsonb_array_length(_res) < 1 THEN _fail := _fail || 'B3 chat list empty'; END IF;
  IF (_res -> 0 ->> 'messages')::int < 1 THEN _fail := _fail || 'B3 message count missing'; END IF;
  IF _res::text LIKE '%secret text%' THEN _fail := _fail || 'B3 message text leaked into the chat list'; END IF;
  BEGIN PERFORM public.admin_message_member_chats('00000000-0000-0000-0000-000000000000', 'M8B probe'); _fail := _fail || 'B3 unknown member accepted';
  EXCEPTION WHEN no_data_found THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M8B FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M8B PASS — word list and a member''s chat list: admin only, reason + log, never the text';
END
$p$;

ROLLBACK;

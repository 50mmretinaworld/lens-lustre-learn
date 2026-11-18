-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1400 — M2c word guard. One transaction, ROLLBACK.
-- Before 20261118_1400: FAIL (message_admin_word_add missing). After: M2c PASS.
--   W1  block word → refused MSG-060, nothing stored
--   W2  hold word → stored as 'held', invisible to the receiver, guard event written
--   W3  help word → delivered, help = true, guard event + admin alert, no message text in the alert
--   W4  strictest hit wins (block beats help in one text); whole-word match ("skill" is not "kill you"); case-insensitive
--   W5  non-ASCII phrase matches as a phrase; a regex-looking rule is only plain text
--   W6  admin can add / switch off a rule with a reason (logged); a member cannot
--   W7  clean text passes
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
CREATE FUNCTION pg_temp.send(_from uuid, _to uuid, _body text) RETURNS text LANGUAGE sql AS $f$
  SELECT pg_temp.as_user(_from, format('SELECT public.message_send(%L, %L, gen_random_uuid())::text', _to, _body));
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _admin uuid; _id bigint; _a0 int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M2c lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_admin_word_add(text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'M2c FAIL: message_admin_word_add missing — expected before 20261118_1400';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m2 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M2c FAIL: need two members and one admin to test with'; END IF;

  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2) AND following_id IN (_m1, _m2);
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_all';
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2), (_m2, _m1);
  INSERT INTO public.conversations (kind, direct_key, created_by)
  VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m1);
  INSERT INTO public.conversation_members (conversation_id, user_id, folder)
  SELECT c.id, u, 'inbox' FROM public.conversations c, unnest(ARRAY[_m1, _m2]) u
   WHERE c.direct_key = least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text);
  DELETE FROM public.message_word_rules;
  INSERT INTO public.message_word_rules (category, pattern, action) VALUES
    ('threat', 'kill you', 'block'), ('political', 'election', 'hold'), ('self_harm', 'suicide', 'help'),
    ('self_harm', 'kill myself', 'help'), ('abuse', 'a.c', 'block'), ('abuse', 'মূর্খ', 'block');

  -- W1
  _r := pg_temp.send(_m1, _m2, 'I will KILL YOU tomorrow');
  IF _r NOT LIKE 'refused 42501 MSG-060%' THEN _fail := _fail || ('W1 block word not refused (case-insensitive): ' || _r); END IF;
  SELECT count(*) INTO _n FROM public.messages WHERE sender_id = _m1 AND body ILIKE '%kill you%';
  IF _n <> 0 THEN _fail := _fail || 'W1 blocked message was stored'; END IF;

  -- W4 whole word, strictest wins
  _r := pg_temp.send(_m1, _m2, 'great skill you have');
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('W4 "skill you" wrongly matched "kill you": ' || _r); END IF;
  _r := pg_temp.send(_m1, _m2, 'suicide and I will kill you');
  IF _r NOT LIKE 'refused 42501 MSG-060%' THEN _fail := _fail || ('W4 block should beat help: ' || _r); END IF;

  -- W5 non-ASCII phrase; regex-looking rule is plain text
  _r := pg_temp.send(_m1, _m2, 'তুমি একটা মূর্খ লোক');
  IF _r NOT LIKE 'refused 42501 MSG-060%' THEN _fail := _fail || ('W5 non-ASCII phrase not matched: ' || _r); END IF;
  _r := pg_temp.send(_m1, _m2, 'abc is a normal word');
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('W5 rule "a.c" acted like a regex and matched "abc": ' || _r); END IF;

  -- W7 clean
  _r := pg_temp.send(_m1, _m2, 'Lovely photo, which lens did you use?');
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('W7 clean text refused: ' || _r); END IF;

  -- W2 hold: the message is stored by the service path to inspect (as_user rolls back), so check the answer instead
  _r := pg_temp.send(_m1, _m2, 'who won the election?');
  IF _r NOT LIKE '%"status": "held"%' THEN _fail := _fail || ('W2 hold word not held: ' || _r); END IF;

  -- W3 help
  SELECT count(*) INTO _a0 FROM public.admin_notifications WHERE type = 'message_help';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m1, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _m1::text, true);
  _r := public.message_send(_m2, 'I want to commit suicide', gen_random_uuid())::text;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  IF _r NOT LIKE '%"help": true%' OR _r NOT LIKE '%"status": "sent"%' THEN _fail := _fail || ('W3 help word: expected delivered + help flag: ' || _r); END IF;
  SELECT count(*) INTO _n FROM public.message_guard_events WHERE user_id = _m1 AND action = 'help';
  IF _n <> 1 THEN _fail := _fail || ('W3 expected 1 help event, got ' || _n); END IF;
  SELECT count(*) INTO _n FROM public.admin_notifications WHERE type = 'message_help';
  IF _n <> _a0 + 1 THEN _fail := _fail || 'W3 admin alert not written'; END IF;
  IF EXISTS (SELECT 1 FROM public.admin_notifications WHERE type = 'message_help' AND message ILIKE '%commit suicide%') THEN
    _fail := _fail || 'W3 alert contains the message text';
  END IF;

  -- W2b held message hidden from the receiver (planted by the service path through the real door's status rule)
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, status)
  SELECT c.id, _m1, 'held one', gen_random_uuid(), 'held' FROM public.conversations c
   WHERE c.direct_key = least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text);
  _r := pg_temp.as_user(_m2, $q$SELECT count(*)::text FROM public.messages WHERE body = 'held one'$q$);
  IF _r <> 'ok 0' THEN _fail := _fail || ('W2 receiver sees a held message: ' || _r); END IF;

  -- W6 admin add / switch, member refused
  _r := pg_temp.as_user(_m1, $q$SELECT public.message_admin_word_add('abuse', 'idiotword', 'en', 'block', 'x')::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('W6 member added a word: ' || _r); END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  _id := public.message_admin_word_add('abuse', 'idiotword', 'en', 'block', 'M2c probe');
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  _r := pg_temp.send(_m1, _m2, 'you are an idiotword');
  IF _r NOT LIKE 'refused 42501 MSG-060%' THEN _fail := _fail || ('W6 new rule not enforced: ' || _r); END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM public.message_admin_word_set_active(_id, false, 'M2c probe');
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  _r := pg_temp.send(_m1, _m2, 'you are an idiotword');
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('W6 switched-off rule still enforced: ' || _r); END IF;
  SELECT count(*) INTO _n FROM public.message_control_log WHERE area = 'word_rule' AND reason = 'M2c probe';
  IF _n <> 2 THEN _fail := _fail || ('W6 expected 2 log rows, got ' || _n); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M2c FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M2c PASS — block / hold / help, whole-word, strictest wins, admin rules logged';
END
$p$;

ROLLBACK;

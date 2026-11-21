-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2700 — M14 reply to one message. One transaction, ROLLBACK.
-- Before 20261118_2700: FAIL (message_send_reply missing). After: M14 PASS.
--   R1  a reply is stored with its link; the thread shows the quote (id, sender, first 140 characters)
--   R2  a reply to a message of ANOTHER chat, a missing message, or no message at all is refused and stores nothing
--   R3  the same send twice (same client id) stores one message and one link
--   R4  the admin's view of the thread is IDENTICAL to the member's (quote included)
--   R5  deleting the quoted message keeps the answer (the quote just disappears)
--   R6  anon cannot use the reply door
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '90s';
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
  _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _conv uuid; _conv23 uuid; _a bigint; _other bigint; _res jsonb; _t jsonb; _t1 jsonb; _t2 jsonb;
  _cid uuid := gen_random_uuid(); _n0 int; _n1 int; _id bigint; _long text := repeat('line of text ', 30);
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M14 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_send_reply(uuid,text,uuid,bigint,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'M14 FAIL: message_send_reply missing — expected before 20261118_2700';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m3 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M14 FAIL: need three members and one admin to test with'; END IF;

  -- the send door open for these three (rolled back with everything else)
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_all';
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2, _m3) AND following_id IN (_m1, _m2, _m3);
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2), (_m2, _m1), (_m2, _m3), (_m3, _m2);

  -- R1 m2 writes a long message, m1 answers it
  PERFORM pg_temp.set_user(_m2);
  _res := public.message_send(_m1, _long, gen_random_uuid());
  _a := (_res ->> 'message_id')::bigint; _conv := (_res ->> 'conversation_id')::uuid;
  PERFORM pg_temp.set_user(_m1);
  _res := public.message_send_reply(_m2, 'this one line is my answer', _cid, _a);
  _id := (_res ->> 'message_id')::bigint;
  IF (SELECT reply_to_id FROM public.messages WHERE id = _id) IS DISTINCT FROM _a THEN _fail := _fail || 'R1 the reply link was not stored'; END IF;
  _t := public.message_thread(_conv);
  IF (_t -> 0 -> 'reply' ->> 'id')::bigint IS DISTINCT FROM _a OR (_t -> 0 -> 'reply' ->> 'sender_id')::uuid IS DISTINCT FROM _m2
     OR char_length(_t -> 0 -> 'reply' ->> 'body') <> 140 THEN
    _fail := _fail || ('R1 the thread quote is wrong: ' || coalesce(left((_t -> 0 -> 'reply')::text, 120), 'null'));
  END IF;
  IF (_t -> 1) ? 'reply' AND (_t -> 1 -> 'reply') <> 'null'::jsonb THEN _fail := _fail || 'R1 a plain message carries a quote'; END IF;

  -- R2 refusals store nothing
  PERFORM pg_temp.set_user(_m3);
  _res := public.message_send(_m2, 'a chat between m3 and m2', gen_random_uuid());
  _other := (_res ->> 'message_id')::bigint;
  PERFORM pg_temp.set_user(_m1);
  SELECT count(*) INTO _n0 FROM public.messages WHERE sender_id = _m1;
  BEGIN PERFORM public.message_send_reply(_m2, 'cross-chat reply', gen_random_uuid(), _other); _fail := _fail || 'R2 a reply to another chat''s message was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.message_send_reply(_m2, 'ghost reply', gen_random_uuid(), 999999999); _fail := _fail || 'R2 a reply to a missing message was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.message_send_reply(_m2, 'no target', gen_random_uuid(), NULL); _fail := _fail || 'R2 a reply with no target was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  SELECT count(*) INTO _n1 FROM public.messages WHERE sender_id = _m1;
  IF _n1 <> _n0 THEN _fail := _fail || ('R2 a refused reply stored a message anyway (' || _n0 || ' → ' || _n1 || ')'); END IF;

  -- R3 the same send twice
  _res := public.message_send_reply(_m2, 'this one line is my answer', _cid, _a);
  IF (_res ->> 'duplicate')::boolean IS NOT TRUE THEN _fail := _fail || 'R3 the second send was not flagged duplicate'; END IF;
  SELECT count(*) INTO _n1 FROM public.messages WHERE sender_id = _m1 AND client_msg_id = _cid;
  IF _n1 <> 1 THEN _fail := _fail || ('R3 the same send stored ' || _n1 || ' messages'); END IF;

  -- R4 the admin sees exactly what the member sees
  PERFORM pg_temp.set_user(_m1);
  _t1 := public.message_thread(_conv);
  PERFORM pg_temp.set_user(_admin);
  _t2 := public.admin_view_thread(_m1, _conv);
  IF _t1::text <> _t2::text THEN _fail := _fail || 'R4 the admin view differs from the member''s own thread'; END IF;

  -- R5 the quoted message goes: the answer stays (the no-delete rule has a service door; this is the engine's path)
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  DELETE FROM public.messages WHERE id = _a;
  IF NOT EXISTS (SELECT 1 FROM public.messages WHERE id = _id AND reply_to_id IS NULL) THEN _fail := _fail || 'R5 deleting the quoted message removed or kept a dead link'; END IF;

  -- R6
  IF has_function_privilege('anon', 'public.message_send_reply(uuid,text,uuid,bigint,jsonb)', 'EXECUTE') THEN _fail := _fail || 'R6 anon can use the reply door'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M14 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M14 PASS — reply stored and quoted, bad targets refused with nothing stored, retry safe, admin view identical, answer survives its quote';
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2400 — M13 message ticks. One transaction, ROLLBACK.
-- Before 20261118_2400: FAIL (message_mark_delivered missing). After: M13 PASS.
--   T1  a fresh message from m1 shows 'sent' to m1; m2's own view of it carries no tick
--   T2  after m2's app marks delivered, m1 sees 'delivered'; the mark is a no-op the second time
--   T3  after m2 reads the chat, m1 sees 'read'; a newer message is again 'sent'
--   T4  the admin's view of m1's thread is IDENTICAL to m1's own (ticks included)
--   T5  a signed-out caller and anon cannot mark delivered; a member cannot call the tick helper
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

-- run a member function AS that member but keep its writes (the function is SECURITY DEFINER; only auth.uid() is switched)
CREATE FUNCTION pg_temp.set_user(_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _m1 uuid; _m2 uuid; _admin uuid; _conv uuid; _msg1 bigint; _msg2 bigint; _t jsonb; _t1 jsonb; _t2 jsonb; _n int;
  _tick text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M13 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_mark_delivered()') IS NULL THEN
    RAISE EXCEPTION 'M13 FAIL: message_mark_delivered missing — expected before 20261118_2400';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m2 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M13 FAIL: need two members and one admin to test with'; END IF;

  -- one chat, m1 sends; m2 has joined an hour ago and has never loaded it
  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_conv, _m1, 'inbox', now() - interval '1 hour'), (_conv, _m2, 'inbox', now() - interval '1 hour');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at) VALUES (_conv, _m1, 'M13 first', gen_random_uuid(), now() - interval '10 minutes') RETURNING id INTO _msg1;

  -- T1
  PERFORM pg_temp.set_user(_m1);
  _t := public.message_thread(_conv);
  _tick := _t -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'sent' THEN _fail := _fail || ('T1a sender should see sent, saw ' || coalesce(_tick, 'null')); END IF;
  PERFORM pg_temp.set_user(_m2);
  _t := public.message_thread(_conv);
  IF (_t -> 0) ? 'tick' AND (_t -> 0 -> 'tick') <> 'null'::jsonb THEN _fail := _fail || 'T1b the receiver must not get a tick on the other person''s message'; END IF;

  -- T2
  PERFORM pg_temp.set_user(_m2);
  _n := public.message_mark_delivered();
  IF _n <> 1 THEN _fail := _fail || ('T2a first mark should touch 1 chat, touched ' || _n); END IF;
  _n := public.message_mark_delivered();
  IF _n <> 0 THEN _fail := _fail || ('T2b second mark should touch 0, touched ' || _n); END IF;
  PERFORM pg_temp.set_user(_m1);
  _tick := public.message_thread(_conv) -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'delivered' THEN _fail := _fail || ('T2c should be delivered, saw ' || coalesce(_tick, 'null')); END IF;

  -- T3
  PERFORM pg_temp.set_user(_m2);
  PERFORM public.message_mark_read(_conv);
  PERFORM pg_temp.set_user(_m1);
  _tick := public.message_thread(_conv) -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'read' THEN _fail := _fail || ('T3a should be read, saw ' || coalesce(_tick, 'null')); END IF;
  -- inside one transaction now() is a single value, so the newer message is stamped a minute ahead
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at) VALUES (_conv, _m1, 'M13 second', gen_random_uuid(), now() + interval '1 minute') RETURNING id INTO _msg2;
  UPDATE public.conversations SET last_message_at = now() WHERE id = _conv;
  _t := public.message_thread(_conv);
  IF (_t -> 0 ->> 'tick') IS DISTINCT FROM 'sent' OR (_t -> 1 ->> 'tick') IS DISTINCT FROM 'read' THEN
    _fail := _fail || ('T3b newest should be sent and the older one read, saw ' || coalesce(_t -> 0 ->> 'tick', 'null') || ' / ' || coalesce(_t -> 1 ->> 'tick', 'null'));
  END IF;

  -- T4
  PERFORM pg_temp.set_user(_m1);
  _t1 := public.message_thread(_conv);
  PERFORM pg_temp.set_user(_admin);
  _t2 := public.admin_view_thread(_m1, _conv);
  IF _t1::text <> _t2::text THEN _fail := _fail || 'T4 the admin view differs from the member''s own thread'; END IF;

  -- T5
  _r := pg_temp.as_user('00000000-0000-0000-0000-000000000000'::uuid, 'SELECT public.message_mark_delivered()::text');
  IF _r NOT LIKE 'refused%' AND _r NOT LIKE 'ok 0' THEN _fail := _fail || ('T5a unknown user: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format('SELECT public.message_tick(%L, %L, now())', _conv, _m1));
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('T5b a member can call the tick helper: ' || _r); END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M13 FAIL: %', array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M13 PASS — ticks: sent / delivered / read, admin view identical, helper closed';
END
$p$;

ROLLBACK;

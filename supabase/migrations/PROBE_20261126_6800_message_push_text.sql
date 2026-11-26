-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261126_6800 message push text. One transaction, ROLLBACK: nothing is kept, no push leaves.
-- FAILS before apply. PASS = switch on: the text (160 cap, one line), "sent a photo" for a wordless photo,
-- the request line for a stranger; switch off: the old fixed line and no text anywhere in the job.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _fail text[] := '{}';
  _m1 uuid; _m2 uuid; _c uuid; _msg bigint; _p jsonb;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.system_flags WHERE key = 'message_push_text') THEN
    RAISE EXCEPTION 'PROBE FAIL: switch message_push_text missing (6800 not applied)';
  END IF;

  -- two ORDINARY members: an admin's chats are always forced into the inbox (20261118_4200), so an
  -- admin sender can never make a "request" and shows as the brand with no picture.
  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false)
     AND NOT public.has_role(p.id, 'admin'::public.app_role) ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1
     AND NOT public.has_role(p.id, 'admin'::public.app_role) ORDER BY p.created_at LIMIT 1;
  IF _m2 IS NULL THEN RAISE EXCEPTION 'PROBE FAIL: need two members to test with'; END IF;

  UPDATE public.system_flags SET value = true WHERE key IN ('job_engine', 'job_engine_push', 'message_push_text');
  DELETE FROM public.notification_preferences WHERE user_id IN (_m1, _m2);
  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'pt6800:' || gen_random_uuid(), _m1) RETURNING id INTO _c;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder) VALUES (_c, _m1, 'inbox'), (_c, _m2, 'inbox');

  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, E'  Hello\n\nthere  ', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT j.payload INTO _p FROM public.jobs j WHERE j.kind = 'push.send' AND j.idempotency_key = 'message:' || _msg || ':' || _m2;
  IF _p ->> 'body' IS DISTINCT FROM 'Hello there' THEN _fail := array_append(_fail, 'text not shown on one line'); END IF;
  IF _p #>> '{data,sender_photo}' IS DISTINCT FROM
     (SELECT nullif(btrim(p.avatar_url), '') FROM public.profiles p WHERE p.id = _m1) THEN
    _fail := array_append(_fail, 'sender photo missing or wrong');
  END IF;

  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, repeat('a', 500), gen_random_uuid()) RETURNING id INTO _msg;
  SELECT j.payload INTO _p FROM public.jobs j WHERE j.kind = 'push.send' AND j.idempotency_key = 'message:' || _msg || ':' || _m2;
  IF char_length(_p ->> 'body') IS DISTINCT FROM 160 THEN _fail := array_append(_fail, 'long text not cut to 160'); END IF;

  INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id) VALUES (_c, _m1, 'photo', '', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT j.payload INTO _p FROM public.jobs j WHERE j.kind = 'push.send' AND j.idempotency_key = 'message:' || _msg || ':' || _m2;
  IF _p ->> 'body' IS DISTINCT FROM 'sent a photo' THEN _fail := array_append(_fail, 'photo line wrong'); END IF;

  UPDATE public.conversation_members SET folder = 'requests' WHERE conversation_id = _c AND user_id = _m2;
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'STRANGER-TEXT', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT j.payload INTO _p FROM public.jobs j WHERE j.kind = 'push.send' AND j.idempotency_key = 'message:' || _msg || ':' || _m2;
  IF _p ->> 'body' IS DISTINCT FROM 'sent you a message request' OR _p::text ILIKE '%STRANGER-TEXT%' THEN _fail := array_append(_fail, 'a request shows text: ' || coalesce(_p ->> 'body', '<no push job>')); END IF;

  UPDATE public.conversation_members SET folder = 'inbox' WHERE conversation_id = _c AND user_id = _m2;
  UPDATE public.system_flags SET value = false WHERE key = 'message_push_text';
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'HIDDEN-TEXT', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT j.payload INTO _p FROM public.jobs j WHERE j.kind = 'push.send' AND j.idempotency_key = 'message:' || _msg || ':' || _m2;
  IF _p ->> 'body' IS DISTINCT FROM 'sent you a message' OR _p::text ILIKE '%HIDDEN-TEXT%' THEN _fail := array_append(_fail, 'switch off still shows text'); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'PROBE FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'PROBE PASS: 6800 message push text — shown, cut, photo line, requests hidden, switch works';
END
$p$;

ROLLBACK;

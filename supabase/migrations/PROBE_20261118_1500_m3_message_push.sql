-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1500 — M3 message push. One transaction, ROLLBACK.
-- Before 20261118_1500: FAIL (messages_push missing). After: M3 PASS.
--   P1  a sent message queues ONE push.send job for the receiver; title = sender name,
--       body is the fixed line, the message text appears nowhere in the job
--   P2  the sender gets no push; a held message gets none; releasing it (held → sent) queues one
--   P3  a muted chat, a declined chat and a member with push off get none
--   P4  a request-folder message uses the request line
--   P5  never twice: replaying the same key does not add a job; engine switch off → no job, send still works
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _fail text[] := '{}';
  _n int; _m1 uuid; _m2 uuid; _m3 uuid; _c uuid; _c2 uuid; _msg bigint; _job record;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M3 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.messages_push()') IS NULL THEN
    RAISE EXCEPTION 'M3 FAIL: messages_push missing — expected before 20261118_1500';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) ORDER BY p.created_at LIMIT 1;
  IF _m3 IS NULL THEN RAISE EXCEPTION 'M3 FAIL: need three members to test with'; END IF;

  UPDATE public.system_flags SET value = true WHERE key IN ('job_engine', 'job_engine_push');
  DELETE FROM public.notification_preferences WHERE user_id IN (_m1, _m2, _m3);

  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'm3probe:' || gen_random_uuid(), _m1) RETURNING id INTO _c;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder) VALUES (_c, _m1, 'inbox'), (_c, _m2, 'inbox');

  -- P1
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'SECRET-TEXT-123', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key = 'message:' || _msg || ':' || _m2;
  IF _n <> 1 THEN _fail := _fail || ('P1 expected 1 push job for the receiver, got ' || _n); END IF;
  SELECT j.payload INTO _job FROM public.jobs j WHERE j.kind = 'push.send' AND j.idempotency_key = 'message:' || _msg || ':' || _m2;
  IF _job.payload IS NULL OR (_job.payload ->> 'user_id')::uuid <> _m2 THEN _fail := _fail || 'P1 push job is not for the receiver'; END IF;
  IF _job.payload::text ILIKE '%SECRET-TEXT-123%' THEN _fail := _fail || 'P1 the message text is inside the push job'; END IF;
  IF _job.payload #>> '{data,type}' <> 'new_message' OR (_job.payload #>> '{data,reference_id}')::uuid <> _c THEN _fail := _fail || 'P1 push data wrong'; END IF;
  IF _job.payload ->> 'body' <> 'sent you a message' THEN _fail := _fail || ('P1 body is ' || (_job.payload ->> 'body')); END IF;

  -- P2
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key = 'message:' || _msg || ':' || _m1;
  IF _n <> 0 THEN _fail := _fail || 'P2 the sender got a push'; END IF;
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, status) VALUES (_c, _m1, 'held text', gen_random_uuid(), 'held') RETURNING id INTO _msg;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key LIKE 'message:' || _msg || ':%';
  IF _n <> 0 THEN _fail := _fail || 'P2 a held message queued a push'; END IF;
  UPDATE public.messages SET status = 'sent' WHERE id = _msg;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key = 'message:' || _msg || ':' || _m2;
  IF _n <> 1 THEN _fail := _fail || ('P2 releasing a held message should queue 1 push, got ' || _n); END IF;

  -- P3
  UPDATE public.conversation_members SET muted = true WHERE conversation_id = _c AND user_id = _m2;
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'to a muted chat', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key LIKE 'message:' || _msg || ':%';
  IF _n <> 0 THEN _fail := _fail || 'P3 a muted chat got a push'; END IF;
  UPDATE public.conversation_members SET muted = false, folder = 'declined' WHERE conversation_id = _c AND user_id = _m2;
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'to a declined chat', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key LIKE 'message:' || _msg || ':%';
  IF _n <> 0 THEN _fail := _fail || 'P3 a declined chat got a push'; END IF;
  UPDATE public.conversation_members SET folder = 'inbox' WHERE conversation_id = _c AND user_id = _m2;
  INSERT INTO public.notification_preferences (user_id, push_enabled) VALUES (_m2, false);
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'push off', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key LIKE 'message:' || _msg || ':%';
  IF _n <> 0 THEN _fail := _fail || 'P3 a member with push off got a push'; END IF;
  DELETE FROM public.notification_preferences WHERE user_id = _m2;

  -- P4 request folder
  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'm3probe2:' || gen_random_uuid(), _m1) RETURNING id INTO _c2;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder) VALUES (_c2, _m1, 'inbox'), (_c2, _m3, 'requests');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c2, _m1, 'hello stranger', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT j.payload INTO _job FROM public.jobs j WHERE j.kind = 'push.send' AND j.idempotency_key = 'message:' || _msg || ':' || _m3;
  IF _job.payload IS NULL OR _job.payload ->> 'body' <> 'sent you a message request' THEN _fail := _fail || 'P4 request line missing'; END IF;

  -- P5 engine switch off: the send still works, no job
  UPDATE public.system_flags SET value = false WHERE key = 'job_engine_push';
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'engine off', gen_random_uuid()) RETURNING id INTO _msg;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'push.send' AND idempotency_key LIKE 'message:' || _msg || ':%';
  IF _n <> 0 THEN _fail := _fail || 'P5 push queued with the push group off'; END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M3 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M3 PASS — message push on the job engine: sender name only, never the text, never twice';
END
$p$;

ROLLBACK;

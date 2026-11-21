-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3500 — M25 chat photo check. One transaction, ROLLBACK.
-- Before 20261118_3500: FAIL (message_photo_to_verify missing). After: M25 PASS.
--   P1  attaching a photo queues exactly one message.photo_verify job (job engine on)
--   P2  message_photo_to_verify returns the path while unchecked, null after
--   P3  mark(ok=true) stamps checked_at only; mark(ok=false) also marks the photo removed (expired_at)
--   P4  a second mark changes nothing; members and visitors cannot run the doors
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _fail text[] := '{}';
  _m1 uuid; _m2 uuid; _conv uuid; _msg bigint; _a1 uuid; _a2 uuid; _n int; _p text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M25 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_photo_to_verify(uuid)') IS NULL THEN
    RAISE EXCEPTION 'M25 FAIL: message_photo_to_verify missing — expected before 20261118_3500';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  IF _m2 IS NULL THEN RAISE EXCEPTION 'M25 FAIL: need two members to test with'; END IF;

  UPDATE public.system_flags SET value = true WHERE key = 'job_engine';
  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text) || ':m25', _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_conv, _m1, 'inbox', now() - interval '1 hour'), (_conv, _m2, 'inbox', now() - interval '1 hour');
  INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id, created_at) VALUES (_conv, _m1, 'photo', '', gen_random_uuid(), now() - interval '10 minutes') RETURNING id INTO _msg;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes, width, height) VALUES (_msg, _m1::text || '/m25-a.webp', 'image/webp', 1000, 10, 10) RETURNING id INTO _a1;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes, width, height) VALUES (_msg, _m1::text || '/m25-b.webp', 'image/webp', 1000, 10, 10) RETURNING id INTO _a2;

  -- P1
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'message.photo_verify' AND idempotency_key IN ('photo-verify:' || _a1::text, 'photo-verify:' || _a2::text);
  IF _n <> 2 THEN _fail := _fail || ('P1 expected 2 queued checks (one per photo), found ' || _n); END IF;

  -- P2
  _p := public.message_photo_to_verify(_a1);
  IF _p IS DISTINCT FROM _m1::text || '/m25-a.webp' THEN _fail := _fail || ('P2 the path to check was ' || coalesce(_p, 'null')); END IF;

  -- P3
  IF NOT public.message_photo_verify_mark(_a1, true) THEN _fail := _fail || 'P3 mark(ok) changed nothing'; END IF;
  IF (SELECT checked_at IS NULL OR expired_at IS NOT NULL FROM public.message_attachments WHERE id = _a1) THEN _fail := _fail || 'P3 a good photo should be checked and NOT removed'; END IF;
  IF public.message_photo_to_verify(_a1) IS NOT NULL THEN _fail := _fail || 'P2 a checked photo is still offered for checking'; END IF;
  IF NOT public.message_photo_verify_mark(_a2, false) THEN _fail := _fail || 'P3 mark(bad) changed nothing'; END IF;
  IF (SELECT checked_at IS NULL OR expired_at IS NULL FROM public.message_attachments WHERE id = _a2) THEN _fail := _fail || 'P3 a fake photo should be checked AND removed'; END IF;

  -- P4
  IF public.message_photo_verify_mark(_a2, true) THEN _fail := _fail || 'P4 a second mark changed something'; END IF;
  IF has_function_privilege('authenticated', 'public.message_photo_to_verify(uuid)', 'EXECUTE') OR has_function_privilege('anon', 'public.message_photo_to_verify(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.message_photo_verify_mark(uuid, boolean)', 'EXECUTE') OR has_function_privilege('anon', 'public.message_photo_verify_mark(uuid, boolean)', 'EXECUTE')
  THEN _fail := _fail || 'P4 a member or visitor can run a verify door'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M25 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M25 PASS — every chat photo is queued for a real-file check; a fake is marked removed; doors closed to members';
END
$p$;

ROLLBACK;

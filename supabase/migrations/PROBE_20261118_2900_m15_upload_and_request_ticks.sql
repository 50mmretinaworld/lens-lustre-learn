-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2900 — M15 photo upload + request ticks. One transaction, ROLLBACK.
-- Before 20261118_2900: FAIL (message_upload_allowed missing) — and the NOTICE "P0 …" shows what a real member upload
-- did before the fix. After: M15 PASS.
--   P1  a member REALLY uploads a file into their own folder of the message-photos bucket (a real INSERT as the
--       authenticated role — the thing the first PROBE never did); another member's folder is refused
--   P2  a request nobody accepted: opening it does not mark it read, the sender keeps ONE tick (sent)
--   P3  accepting moves it to the inbox and counts as read → the sender then sees read; a plain read in the inbox works
--   P4  message_upload_allowed answers about the caller only, and anon cannot run it
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
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 110);
  END;
END
$f$;

CREATE FUNCTION pg_temp.set_user(_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _m1 uuid; _m2 uuid; _conv uuid; _msg bigint; _tick text; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M15 lane %', current_setting('p32.lane', true);

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  IF _m2 IS NULL THEN RAISE EXCEPTION 'M15 FAIL: need two members to test with'; END IF;

  -- the door open for the test (rolled back with everything)
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_all';
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';

  -- P0 / P1 a real upload as the member
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO storage.objects (bucket_id, name, owner, owner_id) VALUES ('message-photos', %L, %L, %L) RETURNING name$q$, _m1::text || '/m15-probe.webp', _m1, _m1::text));
  RAISE NOTICE 'P0 member upload into own folder: %', left(_r, 160);

  IF to_regprocedure('public.message_upload_allowed()') IS NULL THEN
    RAISE EXCEPTION 'M15 FAIL: message_upload_allowed missing — expected before 20261118_2900';
  END IF;

  IF _r NOT LIKE 'ok%' THEN _fail := _fail || ('P1 a member cannot upload into their own folder: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO storage.objects (bucket_id, name, owner, owner_id) VALUES ('message-photos', %L, %L, %L) RETURNING name$q$, _m2::text || '/m15-probe.webp', _m1, _m1::text));
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('P1 a member uploaded into ANOTHER member''s folder: ' || _r); END IF;
  UPDATE public.message_control SET mode = 'blocked_all';
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO storage.objects (bucket_id, name, owner, owner_id) VALUES ('message-photos', %L, %L, %L) RETURNING name$q$, _m1::text || '/m15-probe2.webp', _m1, _m1::text));
  IF _r NOT LIKE 'refused%' THEN _fail := _fail || ('P1 an upload was accepted while messaging is paused for everyone: ' || _r); END IF;
  UPDATE public.message_control SET mode = 'allowed_all';

  -- P2 a request: m1 wrote, m2 has it in Requests
  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_conv, _m1, 'inbox', now() - interval '1 hour'), (_conv, _m2, 'requests', now() - interval '1 hour');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at) VALUES (_conv, _m1, 'M15 hello', gen_random_uuid(), now() - interval '10 minutes') RETURNING id INTO _msg;

  PERFORM pg_temp.set_user(_m2);
  IF public.message_mark_read(_conv) THEN _fail := _fail || 'P2 opening a request marked it read'; END IF;
  PERFORM public.message_mark_delivered();
  PERFORM pg_temp.set_user(_m1);
  _tick := public.message_thread(_conv) -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'sent' THEN _fail := _fail || ('P2 the sender should see ONE tick on an unaccepted request, saw ' || coalesce(_tick, 'null')); END IF;
  IF (SELECT last_read_at FROM public.conversation_members WHERE conversation_id = _conv AND user_id = _m2) IS NOT NULL THEN _fail := _fail || 'P2 the request has a read mark'; END IF;
  PERFORM pg_temp.set_user(_m2);
  _r := public.message_my_conversations('requests', 30, NULL)::text;
  IF _r NOT LIKE '%"unread": 1%' THEN _fail := _fail || ('P2 the request no longer counts as unread: ' || left(_r, 120)); END IF;

  -- P3 accept
  PERFORM public.message_accept_request(_conv);
  PERFORM pg_temp.set_user(_m1);
  _tick := public.message_thread(_conv) -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'read' THEN _fail := _fail || ('P3 after accepting the sender should see read, saw ' || coalesce(_tick, 'null')); END IF;
  UPDATE public.conversation_members SET last_read_at = NULL, last_delivered_at = NULL WHERE conversation_id = _conv AND user_id = _m2;
  PERFORM pg_temp.set_user(_m2);
  IF NOT public.message_mark_read(_conv) THEN _fail := _fail || 'P3 a normal read in the inbox did nothing'; END IF;
  PERFORM pg_temp.set_user(_m1);
  _tick := public.message_thread(_conv) -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'read' THEN _fail := _fail || ('P3 a normal read should show read, saw ' || coalesce(_tick, 'null')); END IF;

  -- P4
  _r := pg_temp.as_user(_m1, $q$SELECT public.message_upload_allowed()::text$q$);
  IF _r <> 'ok true' THEN _fail := _fail || ('P4 message_upload_allowed for a normal member: ' || _r); END IF;
  IF has_function_privilege('anon', 'public.message_upload_allowed()', 'EXECUTE') THEN _fail := _fail || 'P4 anon can run message_upload_allowed'; END IF;

  -- P5 last seen: only for someone you share a chat with, and never when they switched active status off
  UPDATE public.profiles SET last_active_at = now() - interval '12 minutes', privacy_settings = coalesce(privacy_settings, '{}'::jsonb) - 'active_status' WHERE id = _m2;
  _r := pg_temp.as_user(_m1, format($q$SELECT (public.message_peer_status(%L) IS NOT NULL)::text$q$, _m2));
  IF _r <> 'ok true' THEN _fail := _fail || ('P5 a chat partner''s last-active time was not returned: ' || _r); END IF;
  UPDATE public.profiles SET privacy_settings = coalesce(privacy_settings, '{}'::jsonb) || '{"active_status":"off"}'::jsonb WHERE id = _m2;
  _r := pg_temp.as_user(_m1, format($q$SELECT (public.message_peer_status(%L) IS NULL)::text$q$, _m2));
  IF _r <> 'ok true' THEN _fail := _fail || ('P5 last-active shown although the member hid their active status: ' || _r); END IF;
  UPDATE public.profiles SET privacy_settings = coalesce(privacy_settings, '{}'::jsonb) - 'active_status' WHERE id = _m2;
  DELETE FROM public.conversation_members WHERE conversation_id = _conv AND user_id = _m1;
  _r := pg_temp.as_user(_m1, format($q$SELECT (public.message_peer_status(%L) IS NULL)::text$q$, _m2));
  IF _r <> 'ok true' THEN _fail := _fail || ('P5 last-active shown to someone who shares no chat: ' || _r); END IF;
  IF has_function_privilege('anon', 'public.message_peer_status(uuid)', 'EXECUTE') THEN _fail := _fail || 'P5 anon can run message_peer_status'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M15 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M15 PASS — members can upload photos to their own folder only; an unaccepted request shows one tick and stays unread; accepting reads it';
END
$p$;

ROLLBACK;

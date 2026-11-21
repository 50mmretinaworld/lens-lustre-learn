-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3100 — M19 chat photos live 30 days. One transaction, ROLLBACK.
-- Before 20261118_3100: FAIL (message_photos_due missing). After: M19 PASS.
--   P1  a photo older than 30 days is due; a fresh one is not
--   P2  marking expired touches only the old one, once
--   P3  the member's thread says expired:true for the old photo and expired:false for the fresh one
--   P4  members and visitors cannot run the two purge doors; the admin viewer reports expired too
--   P5  the job kind exists and the daily maintenance queues it
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
  _m1 uuid; _m2 uuid; _conv uuid; _msg bigint; _old uuid; _new uuid; _r jsonb; _n int; _e1 text; _e2 text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M19 lane %', current_setting('p32.lane', true);

  IF to_regprocedure('public.message_photos_due(integer)') IS NULL THEN
    RAISE EXCEPTION 'M19 FAIL: message_photos_due missing — expected before 20261118_3100';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  IF _m2 IS NULL THEN RAISE EXCEPTION 'M19 FAIL: need two members to test with'; END IF;

  -- fixture: one chat, one message with two photos (one 31 days old, one fresh)
  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text) || ':m19', _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at) VALUES (_conv, _m1, 'inbox', now() - interval '40 days'), (_conv, _m2, 'inbox', now() - interval '40 days');
  INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id, created_at) VALUES (_conv, _m1, 'photo', '', gen_random_uuid(), now() - interval '31 days') RETURNING id INTO _msg;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes, width, height, created_at)
    VALUES (_msg, _m1::text || '/m19-old.webp', 'image/webp', 1000, 10, 10, now() - interval '31 days') RETURNING id INTO _old;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes, width, height, created_at)
    VALUES (_msg, _m1::text || '/m19-new.webp', 'image/webp', 1000, 10, 10, now() - interval '1 day') RETURNING id INTO _new;

  -- P1
  _r := public.message_photos_due(500);
  IF NOT (_r @> jsonb_build_array(jsonb_build_object('id', _old, 'path', _m1::text || '/m19-old.webp'))) THEN _fail := _fail || 'P1 the 31-day-old photo is not due'; END IF;
  IF _r::text LIKE '%' || _new::text || '%' THEN _fail := _fail || 'P1 a fresh photo is due'; END IF;

  -- P2
  _n := public.message_photos_mark_expired(ARRAY[_old, _new]);
  IF _n <> 1 THEN _fail := _fail || ('P2 expected exactly 1 photo marked expired, got ' || _n); END IF;
  IF (SELECT expired_at FROM public.message_attachments WHERE id = _new) IS NOT NULL THEN _fail := _fail || 'P2 a fresh photo was marked expired'; END IF;
  IF public.message_photos_mark_expired(ARRAY[_old]) <> 0 THEN _fail := _fail || 'P2 an already expired photo was counted again'; END IF;
  IF public.message_photos_due(500)::text LIKE '%' || _old::text || '%' THEN _fail := _fail || 'P2 an expired photo is still due'; END IF;

  -- P3
  PERFORM pg_temp.set_user(_m2);
  _r := public.message_thread(_conv);
  _e1 := (SELECT p ->> 'expired' FROM jsonb_array_elements(_r -> 0 -> 'photos') p WHERE p ->> 'path' = _m1::text || '/m19-old.webp');
  _e2 := (SELECT p ->> 'expired' FROM jsonb_array_elements(_r -> 0 -> 'photos') p WHERE p ->> 'path' = _m1::text || '/m19-new.webp');
  IF _e1 IS DISTINCT FROM 'true' THEN _fail := _fail || ('P3 the old photo should be reported expired:true, got ' || coalesce(_e1, 'null')); END IF;
  IF _e2 IS DISTINCT FROM 'false' THEN _fail := _fail || ('P3 the fresh photo should be reported expired:false, got ' || coalesce(_e2, 'null')); END IF;

  -- P4
  IF has_function_privilege('authenticated', 'public.message_photos_due(integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.message_photos_due(integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.message_photos_mark_expired(uuid[])', 'EXECUTE')
     OR has_function_privilege('anon', 'public.message_photos_mark_expired(uuid[])', 'EXECUTE')
  THEN _fail := _fail || 'P4 a member or visitor can run a purge door'; END IF;
  IF position('''expired''' IN pg_get_functiondef('public.admin_view_thread(uuid,uuid,bigint,integer)'::regprocedure)) = 0 THEN _fail := _fail || 'P4 the admin viewer does not report expired'; END IF;

  -- P5
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'message.photo_purge' AND handler = 'edge:message-photo-purge' AND enabled) THEN _fail := _fail || 'P5 job kind message.photo_purge missing'; END IF;
  IF position('message.photo_purge' IN pg_get_functiondef('public.message_maintenance(jsonb)'::regprocedure)) = 0 THEN _fail := _fail || 'P5 the daily maintenance does not queue the purge'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M19 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M19 PASS — photos older than 30 days are due, marked once, reported as expired; fresh ones untouched; doors closed to members; job queued daily';
END
$p$;

ROLLBACK;

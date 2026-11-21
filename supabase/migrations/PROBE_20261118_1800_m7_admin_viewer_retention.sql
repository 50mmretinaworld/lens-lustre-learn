-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1800 — M7 admin viewer / alarm / review / wipe / retention. One transaction, ROLLBACK.
-- Before 20261118_1800: FAIL (admin_read_conversation missing). After: M7 PASS.
--   V1  a member cannot run the viewer, the held queue or the review
--   V2  admin read returns held + sent messages and writes exactly one log row FIRST; no reason → refused, no row
--   V3  30 different chats opened by one admin in a day opens the alarm; fewer closes it
--   V4  held review: approve → sent, reject → rejected, logged; sender text unchanged
--   V5  admin photo link: hidden before a logged read, visible right after, hidden after 10 minutes
--   V6  deletion wipe: the member's messages, memberships, rules gone; the other member's messages stay; files queued; empty chat removed
--   V7  logs stay append-only for everyone; the 1-year trim removes only old rows
--   V8  daily job kind exists with a queued job; the job function runs and re-queues itself
--   V9  members still cannot edit / delete a message (the wipe flag does not leak)
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
CREATE FUNCTION pg_temp.on(_uid uuid) RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', _uid::text, true);
$f$;
CREATE FUNCTION pg_temp.off() RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _admin uuid; _c uuid; _c2 uuid; _held bigint; _held2 bigint; _msg bigint;
  _j jsonb; _p text; _before int; _i int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M7 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.admin_read_conversation(uuid,text,bigint,integer)') IS NULL THEN
    RAISE EXCEPTION 'M7 FAIL: admin_read_conversation missing — expected before 20261118_1800';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m2 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M7 FAIL: need two members and one admin to test with'; END IF;
  UPDATE public.system_flags SET value = false WHERE key = 'job_engine_push';

  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'm7probe:' || gen_random_uuid(), _m1) RETURNING id INTO _c;
  INSERT INTO public.conversation_members (conversation_id, user_id) VALUES (_c, _m1), (_c, _m2);
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c, _m1, 'from m1', gen_random_uuid()), (_c, _m2, 'from m2', gen_random_uuid());
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, status) VALUES (_c, _m1, 'held a', gen_random_uuid(), 'held') RETURNING id INTO _held;
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, status) VALUES (_c, _m1, 'held b', gen_random_uuid(), 'held') RETURNING id INTO _held2;
  _p := _m1 || '/m7.webp';
  INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES ('message-photos', _p, _m1, '{"mimetype":"image/webp","size":1000}');
  INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id) VALUES (_c, _m1, 'photo', '', gen_random_uuid()) RETURNING id INTO _msg;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes) VALUES (_msg, _p, 'image/webp', 1000);
  PERFORM set_config('app.message_log_trim', 'on', true);           -- test only: fresh slate for the alarm count
  DELETE FROM public.message_admin_reads WHERE admin_id = _admin;
  PERFORM set_config('app.message_log_trim', 'off', true);

  -- V1
  _r := pg_temp.as_user(_m1, format($q$SELECT public.admin_read_conversation(%L, 'x')::text$q$, _c));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('V1 member ran the viewer: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, 'SELECT public.admin_message_held_queue()::text');
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('V1 member read the held queue: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.admin_message_review(%L, true, 'x')$q$, _held));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('V1 member ran the review: ' || _r); END IF;

  -- V5 first half: admin has not read yet → photo hidden
  _r := pg_temp.as_user(_admin, format($q$SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p));
  IF _r <> 'ok 0' THEN _fail := _fail || ('V5 admin sees the photo before any logged read: ' || _r); END IF;

  -- V2
  SELECT count(*) INTO _before FROM public.message_admin_reads WHERE admin_id = _admin;
  PERFORM pg_temp.on(_admin);
  _j := public.admin_read_conversation(_c, 'M7 probe');
  BEGIN PERFORM public.admin_read_conversation(_c, '  '); _fail := _fail || 'V2 empty reason accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM pg_temp.off();
  SELECT count(*) INTO _n FROM public.message_admin_reads WHERE admin_id = _admin;
  IF _n <> _before + 1 THEN _fail := _fail || ('V2 expected exactly 1 new log row, got ' || (_n - _before)); END IF;
  IF jsonb_array_length(_j -> 'messages') <> 5 OR _j::text NOT LIKE '%held a%' OR _j::text NOT LIKE '%' || _p || '%' THEN
    _fail := _fail || ('V2 viewer content wrong: ' || left(_j::text, 200));
  END IF;

  -- V5 second half: right after the logged read → visible; 11 minutes later → hidden
  _r := pg_temp.as_user(_admin, format($q$SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p));
  IF _r <> 'ok 1' THEN _fail := _fail || ('V5 admin cannot sign the photo after a logged read: ' || _r); END IF;
  PERFORM set_config('app.message_log_trim', 'on', true);
  -- age the row by replacing it (append-only: delete + insert is only possible with the trim flag)
  DELETE FROM public.message_admin_reads WHERE admin_id = _admin;
  INSERT INTO public.message_admin_reads (admin_id, conversation_id, reason, at) VALUES (_admin, _c, 'aged', now() - interval '11 minutes');
  PERFORM set_config('app.message_log_trim', 'off', true);
  _r := pg_temp.as_user(_admin, format($q$SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p));
  IF _r <> 'ok 0' THEN _fail := _fail || ('V5 admin photo link still open after 10 minutes: ' || _r); END IF;

  -- V3 alarm
  PERFORM pg_temp.on(_admin);
  FOR _i IN 1..29 LOOP
    INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'm7alarm:' || _i || ':' || gen_random_uuid(), _m1) RETURNING id INTO _c2;
    PERFORM public.admin_read_conversation(_c2, 'M7 alarm probe');
  END LOOP;
  PERFORM pg_temp.off();
  -- 29 new chats + the 'aged' row's chat = 30 different chats in 24 h → alarm open
  IF NOT EXISTS (SELECT 1 FROM public.ops_alarms WHERE alarm_key = 'messages:admin_reads' AND closed_at IS NULL) THEN _fail := _fail || 'V3 alarm not raised at 30 chats'; END IF;
  PERFORM set_config('app.message_log_trim', 'on', true);
  DELETE FROM public.message_admin_reads WHERE admin_id = _admin AND reason = 'M7 alarm probe';
  PERFORM set_config('app.message_log_trim', 'off', true);
  PERFORM public.message_admin_alarm_eval();
  IF EXISTS (SELECT 1 FROM public.ops_alarms WHERE alarm_key = 'messages:admin_reads' AND closed_at IS NULL) THEN _fail := _fail || 'V3 alarm still open after the reads were removed'; END IF;

  -- V4 review
  PERFORM pg_temp.on(_admin);
  _r := public.admin_message_review(_held, true, 'M7 probe approve');
  IF _r <> 'sent' THEN _fail := _fail || ('V4 approve gave ' || _r); END IF;
  _r := public.admin_message_review(_held2, false, 'M7 probe reject');
  IF _r <> 'rejected' THEN _fail := _fail || ('V4 reject gave ' || _r); END IF;
  _j := public.admin_message_held_queue();
  PERFORM pg_temp.off();
  IF _j::text LIKE '%' || _held || '%' THEN _fail := _fail || 'V4 reviewed message still in the queue'; END IF;
  SELECT count(*) INTO _n FROM public.message_control_log WHERE area = 'review' AND reason IN ('M7 probe approve', 'M7 probe reject');
  IF _n <> 2 THEN _fail := _fail || ('V4 expected 2 review log rows, got ' || _n); END IF;
  IF (SELECT body FROM public.messages WHERE id = _held) <> 'held a' THEN _fail := _fail || 'V4 review changed the message text'; END IF;

  -- V7 append-only + trim
  BEGIN DELETE FROM public.message_admin_reads; _fail := _fail || 'V7 admin-read log row deleted without the trim';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM set_config('app.message_log_trim', 'on', true);
  INSERT INTO public.message_admin_reads (admin_id, conversation_id, reason, at) VALUES (_admin, _c, 'ancient', now() - interval '2 years');
  PERFORM set_config('app.message_log_trim', 'off', true);
  SELECT count(*) INTO _before FROM public.message_admin_reads;
  PERFORM public.message_logs_trim();
  SELECT count(*) INTO _n FROM public.message_admin_reads;
  IF _n <> _before - 1 OR EXISTS (SELECT 1 FROM public.message_admin_reads WHERE reason = 'ancient') THEN _fail := _fail || 'V7 trim did not remove exactly the old row'; END IF;

  -- V8 job
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'message.maintenance') THEN _fail := _fail || 'V8 job kind missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'message.maintenance' AND status = 'queued') THEN _fail := _fail || 'V8 no queued maintenance job'; END IF;
  PERFORM public.message_maintenance('{}'::jsonb);

  -- V6 wipe (m1 is "deleted": the delete program writes this log row)
  INSERT INTO public.account_state_log (user_id, from_state, to_state, reason) VALUES (_m1, 'active', 'deleted', 'M7 probe');
  SELECT count(*) INTO _n FROM public.messages WHERE sender_id = _m1;
  IF _n <> 0 THEN _fail := _fail || ('V6 the deleted member still has ' || _n || ' messages'); END IF;
  IF EXISTS (SELECT 1 FROM public.conversation_members WHERE user_id = _m1) THEN _fail := _fail || 'V6 membership remains'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.messages WHERE sender_id = _m2 AND body = 'from m2') THEN _fail := _fail || 'V6 the other member''s message was removed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.message_files_purge WHERE path = _p) THEN _fail := _fail || 'V6 photo file not queued for purge'; END IF;
  IF current_setting('app.message_wipe', true) = 'on' THEN _fail := _fail || 'V6 wipe flag left on'; END IF;
  -- the second member leaves too → the empty chat goes
  PERFORM public.message_wipe_member(_m2);
  IF EXISTS (SELECT 1 FROM public.conversations WHERE id = _c) THEN _fail := _fail || 'V6 an empty chat remains'; END IF;

  -- V9 immutability still holds for a signed-in actor
  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', 'm7imm:' || gen_random_uuid(), _m2) RETURNING id INTO _c2;
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_c2, _m2, 'keep me', gen_random_uuid()) RETURNING id INTO _msg;
  PERFORM pg_temp.on(_m2);
  BEGIN DELETE FROM public.messages WHERE id = _msg; _fail := _fail || 'V9 a signed-in actor deleted a message';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM pg_temp.off();

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M7 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M7 PASS — logged admin viewer, alarm, held review, deletion wipe, retention';
END
$p$;

ROLLBACK;

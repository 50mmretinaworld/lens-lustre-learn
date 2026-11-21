-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2300 — M12 broadcast. One transaction, ROLLBACK.
-- Before 20261118_2300: FAIL (admin_message_broadcast_save missing). After: M12 PASS.
--   E1  a member cannot use any broadcast function
--   E2  save: bad title / foreign or missing picture refused; only a draft can be edited
--   E3  audience count; send cuts the audience into batches, queues one job per batch
--   E4  the batch job puts the message into each member's box (their own screen shows it, unread 1)
--   E5  run twice = never two copies; a blocked member fails with the reason, the rest are delivered
--   E6  read / unread, filters, search, paging, per-batch numbers in the report
--   E7  pause holds the batch, resume re-queues it, cancel stops it; a scheduled send waits
--   E8  a picture is shared by every copy and opens for the members, not for outsiders
--   E9  withdraw removes every copy (pictures too) and the chat disappears from the member's list
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '90s';
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
  _r text; _n int; _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _res jsonb; _id bigint; _id2 bigint; _id3 bigint; _id4 bigint;
  _batch bigint; _path text; _conv uuid; _msgs int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M12 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.admin_message_broadcast_save(bigint,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'M12 FAIL: admin_message_broadcast_save missing — expected before 20261118_2300';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND public.account_can_act(p.id) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND public.account_can_act(p.id) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND public.account_can_act(p.id) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m3 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M12 FAIL: need three members and one admin to test with'; END IF;

  -- E1 member cannot
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_broadcast_save(NULL, '{"title":"x","body":"y"}'::jsonb)::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGBC-001%' THEN _fail := _fail || ('E1 member saved a broadcast: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_broadcasts(NULL, 25, 0)::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGBC-001%' THEN _fail := _fail || ('E1 member listed broadcasts: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_broadcast_send(1, NULL)::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGBC-001%' THEN _fail := _fail || ('E1 member sent a broadcast: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_broadcast_audience('{"kind":"all"}'::jsonb)::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGBC-001%' THEN _fail := _fail || ('E1 member counted an audience: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_broadcast_withdraw(1)::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGBC-001%' THEN _fail := _fail || ('E1 member withdrew a broadcast: ' || _r); END IF;

  -- everything below as the admin
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);

  -- E2 save
  BEGIN PERFORM public.admin_message_broadcast_save(NULL, '{"title":"  ","body":"x"}'::jsonb); _fail := _fail || 'E2 empty title accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.admin_message_broadcast_save(NULL, jsonb_build_object('title', 'T', 'body', 'x', 'photos',
          jsonb_build_array(jsonb_build_object('path', _m1::text || '/theirs.webp', 'mime', 'image/webp')))); _fail := _fail || 'E2 a picture from another folder accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.admin_message_broadcast_save(NULL, '{"title":"T","body":"x","audience":{"kind":"everyone"}}'::jsonb); _fail := _fail || 'E2 unknown audience accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  _id := public.admin_message_broadcast_save(NULL, jsonb_build_object('title', 'M12 probe', 'body', 'Welcome to the new messages 👋 https://50mmretina.com',
          'audience', jsonb_build_object('kind', 'members', 'ids', jsonb_build_array(_m1, _m2)), 'push', false));
  IF _id IS NULL THEN _fail := _fail || 'E2 save returned nothing'; END IF;
  PERFORM public.admin_message_broadcast_save(_id, jsonb_build_object('title', 'M12 probe', 'body', 'Welcome to the new messages 👋 https://50mmretina.com',
          'audience', jsonb_build_object('kind', 'members', 'ids', jsonb_build_array(_m1, _m2)), 'push', false));

  -- E3 audience + send
  _res := public.admin_message_broadcast_audience(jsonb_build_object('kind', 'members', 'ids', jsonb_build_array(_m1, _m2, _admin)));
  IF (_res ->> 'matched')::int <> 3 OR (_res ->> 'will_receive')::int <> 2 THEN _fail := _fail || ('E3 audience count wrong (the sender must be left out): ' || _res::text); END IF;
  _res := public.admin_message_broadcast_send(_id, NULL);
  IF (_res ->> 'recipients')::int <> 2 OR (_res ->> 'batches')::int <> 1 THEN _fail := _fail || ('E3 send answer wrong: ' || _res::text); END IF;
  SELECT id INTO _batch FROM public.message_broadcast_batches WHERE broadcast_id = _id AND seq = 1;
  IF _batch IS NULL THEN _fail := _fail || 'E3 no batch row'; END IF;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'message.broadcast_batch' AND (payload ->> 'batch_id')::bigint = _batch;
  IF _n <> 1 THEN _fail := _fail || ('E3 expected one queued job for the batch, got ' || _n); END IF;
  BEGIN PERFORM public.admin_message_broadcast_send(_id, NULL); _fail := _fail || 'E3 a sent broadcast could be sent again';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.admin_message_broadcast_save(_id, '{"title":"changed","body":"x"}'::jsonb); _fail := _fail || 'E2 a sent broadcast could be edited';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;

  -- E4 the batch job (runs as the job engine: no signed-in user)
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM public.message_broadcast_run_batch(jsonb_build_object('batch_id', _batch));
  SELECT count(*) INTO _msgs FROM public.messages WHERE sender_id = _admin AND body LIKE 'Welcome to the new messages%';
  IF _msgs <> 2 THEN _fail := _fail || ('E4 expected 2 stored messages, got ' || _msgs); END IF;
  IF (SELECT status FROM public.message_broadcasts WHERE id = _id) <> 'done' THEN _fail := _fail || 'E4 broadcast not done'; END IF;
  IF (SELECT delivered FROM public.message_broadcast_batches WHERE id = _batch) <> 2 THEN _fail := _fail || 'E4 batch delivered count wrong'; END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.message_my_conversations('inbox', 30, NULL)::text$q$);
  IF _r NOT LIKE '%Welcome to the new messages%' OR _r NOT LIKE '%"unread": 1%' THEN _fail := _fail || ('E4 the member does not see it unread in their box: ' || left(_r, 160)); END IF;
  SELECT conversation_id INTO _conv FROM public.message_broadcast_recipients WHERE broadcast_id = _id AND user_id = _m1;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_thread(%L, NULL, 50)::text$q$, _conv));
  IF _r NOT LIKE '%Welcome to the new messages%' THEN _fail := _fail || ('E4 the member thread does not show it: ' || left(_r, 160)); END IF;

  -- E5 run twice = no second copy; blocked member fails with the reason
  UPDATE public.message_broadcast_recipients SET status = 'waiting' WHERE broadcast_id = _id;
  UPDATE public.message_broadcast_batches SET status = 'waiting' WHERE id = _batch;
  PERFORM public.message_broadcast_run_batch(jsonb_build_object('batch_id', _batch));
  SELECT count(*) INTO _msgs FROM public.messages WHERE sender_id = _admin AND body LIKE 'Welcome to the new messages%';
  IF _msgs <> 2 THEN _fail := _fail || ('E5 a retry stored a second copy: ' || _msgs); END IF;
  IF (SELECT count(*) FROM public.message_broadcast_recipients WHERE broadcast_id = _id AND status = 'delivered') <> 2 THEN _fail := _fail || 'E5 recipients not delivered again'; END IF;

  INSERT INTO public.user_blocks (blocker_id, blocked_id) VALUES (_m2, _admin) ON CONFLICT DO NOTHING;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  _id2 := public.admin_message_broadcast_save(NULL, jsonb_build_object('title', 'M12 second', 'body', 'Second one',
          'audience', jsonb_build_object('kind', 'members', 'ids', jsonb_build_array(_m1, _m2)), 'push', false));
  PERFORM public.admin_message_broadcast_send(_id2, NULL);
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM public.message_broadcast_run_batch(jsonb_build_object('batch_id', (SELECT id FROM public.message_broadcast_batches WHERE broadcast_id = _id2 AND seq = 1)));
  SELECT error INTO _r FROM public.message_broadcast_recipients WHERE broadcast_id = _id2 AND user_id = _m2 AND status = 'failed';
  IF _r IS DISTINCT FROM 'blocked' THEN _fail := _fail || ('E5 the blocked member was not recorded as failed/blocked: ' || coalesce(_r, 'no row')); END IF;
  IF (SELECT status FROM public.message_broadcast_recipients WHERE broadcast_id = _id2 AND user_id = _m1) <> 'delivered' THEN _fail := _fail || 'E5 the other member was not delivered'; END IF;
  DELETE FROM public.user_blocks WHERE blocker_id = _m2 AND blocked_id = _admin;

  -- E6 report: read / unread, filters, search, paging
  UPDATE public.conversation_members SET last_read_at = now() + interval '1 second' WHERE conversation_id = _conv AND user_id = _m1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  _res := public.admin_message_broadcast_report(_id);
  IF (_res -> 'totals' ->> 'delivered')::int <> 2 OR (_res -> 'totals' ->> 'read')::int <> 1 OR (_res -> 'totals' ->> 'unread')::int <> 1
     OR (_res -> 'totals' ->> 'audience')::int <> 2 OR jsonb_array_length(_res -> 'batches') <> 1 THEN _fail := _fail || ('E6 report totals wrong: ' || (_res -> 'totals')::text); END IF;
  _res := public.admin_message_broadcast_recipients(_id, 'read', NULL, 25, 0);
  IF (_res ->> 'total')::int <> 1 OR (_res -> 'rows' -> 0 ->> 'user_id') <> _m1::text THEN _fail := _fail || ('E6 read filter wrong: ' || left(_res::text, 200)); END IF;
  _res := public.admin_message_broadcast_recipients(_id, 'unread', NULL, 25, 0);
  IF (_res ->> 'total')::int <> 1 OR (_res -> 'rows' -> 0 ->> 'user_id') <> _m2::text THEN _fail := _fail || ('E6 unread filter wrong: ' || left(_res::text, 200)); END IF;
  _res := public.admin_message_broadcast_recipients(_id2, 'failed', NULL, 25, 0);
  IF (_res ->> 'total')::int <> 1 OR (_res -> 'rows' -> 0 ->> 'error') <> 'blocked' THEN _fail := _fail || ('E6 failed filter wrong: ' || left(_res::text, 200)); END IF;
  _res := public.admin_message_broadcast_recipients(_id, 'all', NULL, 1, 0);
  IF jsonb_array_length(_res -> 'rows') <> 1 OR (_res ->> 'total')::int <> 2 THEN _fail := _fail || 'E6 paging wrong'; END IF;
  _res := public.admin_message_broadcasts(NULL, 25, 0);
  IF (_res ->> 'total')::int < 2 OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(_res -> 'rows') x WHERE (x ->> 'id')::bigint = _id AND (x ->> 'read')::int = 1 AND (x ->> 'delivered')::int = 2) THEN
    _fail := _fail || ('E6 broadcast list wrong: ' || left(_res::text, 200));
  END IF;
  BEGIN PERFORM public.admin_message_broadcast_control(_id2, 'retry_failed'); EXCEPTION WHEN OTHERS THEN _fail := _fail || ('E6 retry_failed refused: ' || SQLERRM); END;
  IF (SELECT status FROM public.message_broadcast_recipients WHERE broadcast_id = _id2 AND user_id = _m2) <> 'waiting' THEN _fail := _fail || 'E6 retry did not put the failed member back to waiting'; END IF;

  -- E7 scheduled · pause · resume · cancel
  _id3 := public.admin_message_broadcast_save(NULL, jsonb_build_object('title', 'M12 later', 'body', 'Later one',
          'audience', jsonb_build_object('kind', 'members', 'ids', jsonb_build_array(_m1, _m3)), 'push', false));
  PERFORM public.admin_message_broadcast_send(_id3, now() + interval '2 hours');
  IF (SELECT status FROM public.message_broadcasts WHERE id = _id3) <> 'scheduled' THEN _fail := _fail || 'E7 a later send is not scheduled'; END IF;
  PERFORM public.admin_message_broadcast_control(_id3, 'pause');
  IF (SELECT status FROM public.message_broadcasts WHERE id = _id3) <> 'paused' THEN _fail := _fail || 'E7 pause failed'; END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM public.message_broadcast_run_batch(jsonb_build_object('batch_id', (SELECT id FROM public.message_broadcast_batches WHERE broadcast_id = _id3 AND seq = 1)));
  IF EXISTS (SELECT 1 FROM public.messages WHERE body = 'Later one') THEN _fail := _fail || 'E7 a paused broadcast delivered'; END IF;
  IF (SELECT status FROM public.message_broadcast_batches WHERE broadcast_id = _id3 AND seq = 1) <> 'waiting' THEN _fail := _fail || 'E7 a paused batch is not waiting'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM public.admin_message_broadcast_control(_id3, 'resume');
  IF (SELECT status FROM public.message_broadcasts WHERE id = _id3) <> 'sending' THEN _fail := _fail || 'E7 resume failed'; END IF;
  PERFORM public.admin_message_broadcast_control(_id3, 'cancel');
  IF (SELECT status FROM public.message_broadcasts WHERE id = _id3) <> 'cancelled'
     OR (SELECT status FROM public.message_broadcast_batches WHERE broadcast_id = _id3 AND seq = 1) <> 'cancelled' THEN _fail := _fail || 'E7 cancel failed'; END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM public.message_broadcast_run_batch(jsonb_build_object('batch_id', (SELECT id FROM public.message_broadcast_batches WHERE broadcast_id = _id3 AND seq = 1)));
  IF EXISTS (SELECT 1 FROM public.messages WHERE body = 'Later one') THEN _fail := _fail || 'E7 a cancelled broadcast delivered'; END IF;

  -- E8 one picture shared by every copy
  _path := _admin::text || '/m12-probe.webp';
  INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES ('message-photos', _path, _admin, '{"mimetype":"image/webp","size":50000}');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  _id4 := public.admin_message_broadcast_save(NULL, jsonb_build_object('title', 'M12 picture', 'body', '',
          'photos', jsonb_build_array(jsonb_build_object('path', _path, 'mime', 'image/webp', 'bytes', 50000, 'width', 900, 'height', 600)),
          'audience', jsonb_build_object('kind', 'members', 'ids', jsonb_build_array(_m1, _m3)), 'push', false));
  PERFORM public.admin_message_broadcast_send(_id4, NULL);
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM public.message_broadcast_run_batch(jsonb_build_object('batch_id', (SELECT id FROM public.message_broadcast_batches WHERE broadcast_id = _id4 AND seq = 1)));
  SELECT count(*) INTO _n FROM public.message_attachments WHERE storage_path = _path;
  IF _n <> 2 THEN _fail := _fail || ('E8 expected the picture on 2 messages, got ' || _n); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_photo_visible(%L)::text$q$, _path));
  IF _r <> 'ok true' THEN _fail := _fail || ('E8 the member cannot open the broadcast picture: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, format($q$SELECT public.message_photo_visible(%L)::text$q$, _path));
  IF _r <> 'ok false' THEN _fail := _fail || ('E8 a member who did not get it can open the picture: ' || _r); END IF;

  -- E9 withdraw
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  PERFORM public.admin_message_broadcast_withdraw(_id4);
  IF (SELECT status FROM public.message_broadcasts WHERE id = _id4) <> 'withdrawn' THEN _fail := _fail || 'E9 status not withdrawn'; END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM public.message_broadcast_withdraw_run(jsonb_build_object('broadcast_id', _id4));
  IF EXISTS (SELECT 1 FROM public.message_attachments WHERE storage_path = _path) THEN _fail := _fail || 'E9 pictures were not removed'; END IF;
  IF (SELECT count(*) FROM public.message_broadcast_recipients WHERE broadcast_id = _id4 AND status = 'withdrawn') <> 2 THEN _fail := _fail || 'E9 recipients not marked withdrawn'; END IF;
  _r := pg_temp.as_user(_m3, $q$SELECT public.message_my_conversations('inbox', 30, NULL)::text$q$);
  IF _r LIKE '%' || _admin::text || '%' AND _r LIKE '%"kind": "photo"%' THEN _fail := _fail || ('E9 the withdrawn picture message is still in the member list: ' || left(_r, 160)); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M12 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M12 PASS — broadcast in batches: delivered / failed / read per batch and member, never twice, pause / resume / cancel / retry / withdraw';
END
$p$;

ROLLBACK;

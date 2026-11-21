-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2200 — M11 admin opens a member's message box. One transaction, ROLLBACK.
-- Before 20261118_2200: FAIL (admin_view_inbox missing). After: M11 PASS.
--   D1  a member cannot run any of the admin functions
--   D2  the admin's inbox view of a member is IDENTICAL to what that member's own screen gets
--   D3  the admin's thread view is IDENTICAL to the member's own thread; another member's chat is refused
--   D4  viewing writes nothing: no log row, no admin-read row, no read mark, no unread change
--   D5  the member table: search by name, filters + counts, sort, paging, bad sort refused
--   D6  an admin can open any chat photo; a member outside the chat cannot
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

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _a text; _n int; _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _conv uuid; _res jsonb; _msg bigint;
  _log0 int; _reads0 int; _lastread0 timestamptz; _lastread1 timestamptz; _name text; _row jsonb;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M11 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.admin_view_inbox(uuid,text,integer,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'M11 FAIL: admin_view_inbox missing — expected before 20261118_2200';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m3 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M11 FAIL: need three members and one admin to test with'; END IF;

  -- a chat between m1 and m2 with two messages from m2 (unread for m1), and a chat between m2 and m3 (not m1's)
  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text), _m2, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder) VALUES (_conv, _m1, 'inbox'), (_conv, _m2, 'inbox');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_conv, _m2, 'M11 first', gen_random_uuid());
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id) VALUES (_conv, _m2, 'M11 second', gen_random_uuid()) RETURNING id INTO _msg;
  INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes) VALUES (_msg, _m2::text || '/m11-probe.webp', 'image/webp', 1000);

  -- D1 member cannot
  _r := pg_temp.as_user(_m1, format($q$SELECT public.admin_view_inbox(%L, 'inbox', 30, NULL)::text$q$, _m2));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('D1 member opened a box: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.admin_view_thread(%L, %L, NULL, 50)::text$q$, _m2, _conv));
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('D1 member opened a thread: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, $q$SELECT public.admin_message_member_search(NULL, 'all', 'name', 'asc', 25, 0)::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('D1 member searched members: ' || _r); END IF;

  SELECT count(*) INTO _log0 FROM public.message_control_log;
  SELECT count(*) INTO _reads0 FROM public.message_admin_reads;
  SELECT last_read_at INTO _lastread0 FROM public.conversation_members WHERE conversation_id = _conv AND user_id = _m1;

  -- D2 identical inbox
  _a := pg_temp.as_user(_m1, $q$SELECT public.message_my_conversations('inbox', 30, NULL)::text$q$);
  _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_view_inbox(%L, 'inbox', 30, NULL)::text$q$, _m1));
  IF _a NOT LIKE 'ok %' OR _a <> _r THEN _fail := _fail || ('D2 inbox differs: member=' || left(_a, 120) || ' admin=' || left(_r, 120)); END IF;
  IF _a NOT LIKE '%M11 second%' THEN _fail := _fail || 'D2 the test chat is missing from the member inbox'; END IF;

  -- D3 identical thread, foreign chat refused
  _a := pg_temp.as_user(_m1, format($q$SELECT public.message_thread(%L, NULL, 50)::text$q$, _conv));
  _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_view_thread(%L, %L, NULL, 50)::text$q$, _m1, _conv));
  IF _a NOT LIKE 'ok %' OR _a <> _r THEN _fail := _fail || ('D3 thread differs: member=' || left(_a, 120) || ' admin=' || left(_r, 120)); END IF;
  _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_view_thread(%L, %L, NULL, 50)::text$q$, _m3, _conv));
  IF _r NOT LIKE 'refused 42501 MSG-071%' THEN _fail := _fail || ('D3 admin read a chat the member is not in: ' || _r); END IF;

  -- D4 nothing written
  SELECT last_read_at INTO _lastread1 FROM public.conversation_members WHERE conversation_id = _conv AND user_id = _m1;
  IF (SELECT count(*) FROM public.message_control_log) <> _log0 THEN _fail := _fail || 'D4 a control-log row was written'; END IF;
  IF (SELECT count(*) FROM public.message_admin_reads) <> _reads0 THEN _fail := _fail || 'D4 an admin-read row was written'; END IF;
  IF _lastread1 IS DISTINCT FROM _lastread0 THEN _fail := _fail || 'D4 the member''s read mark moved'; END IF;
  _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_view_inbox(%L, 'inbox', 30, NULL)::text$q$, _m1));
  IF _r NOT LIKE '%"unread": 2%' THEN _fail := _fail || ('D4 unread count changed or missing: ' || left(_r, 200)); END IF;

  -- D5 the member table
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  SELECT full_name INTO _name FROM public.profiles WHERE id = _m1;
  IF coalesce(btrim(_name), '') <> '' THEN
    _res := public.admin_message_member_search(left(_name, 3), 'all', 'name', 'asc', 25, 0);
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(_res -> 'rows') x WHERE x ->> 'user_id' = _m1::text) THEN _fail := _fail || 'D5 search by name did not find the member'; END IF;
  END IF;
  _res := public.admin_message_member_search(NULL, 'active', 'chats', 'desc', 100, 0);
  SELECT x INTO _row FROM jsonb_array_elements(_res -> 'rows') x WHERE x ->> 'user_id' = _m1::text;
  IF _row IS NULL OR jsonb_array_length(_row -> 'chatting_with') < 1 OR (_row -> 'chatting_with' -> 0 ->> 'user_id') IS DISTINCT FROM _m2::text THEN
    _fail := _fail || ('D5 "chatting with" missing or wrong for the member: ' || left(coalesce(_row::text, 'no row'), 160));
  END IF;
  IF (_res -> 'counts' ->> 'active')::int < 2 THEN _fail := _fail || 'D5 active count too small'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(_res -> 'rows') x WHERE (x ->> 'chats')::int = 0) THEN _fail := _fail || 'D5 active filter returned a member without chats'; END IF;
  IF (_res -> 'rows' -> 0 ->> 'chats')::int < (_res -> 'rows' -> (jsonb_array_length(_res -> 'rows') - 1) ->> 'chats')::int THEN _fail := _fail || 'D5 sort by chats desc is not descending'; END IF;
  _res := public.admin_message_member_search(NULL, 'all', 'name', 'asc', 1, 0);
  IF jsonb_array_length(_res -> 'rows') <> 1 OR (_res ->> 'total')::int < 3 THEN _fail := _fail || 'D5 paging wrong'; END IF;
  IF (_res -> 'counts' ->> 'all')::int < (_res ->> 'total')::int THEN _fail := _fail || 'D5 counts.all smaller than total'; END IF;
  BEGIN PERFORM public.admin_message_member_search(NULL, 'all', 'email; drop', 'asc', 25, 0); _fail := _fail || 'D5 bad sort accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM public.admin_message_member_search(NULL, 'everyone', 'name', 'asc', 25, 0); _fail := _fail || 'D5 bad filter accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);

  -- D6 photos
  _r := pg_temp.as_user(_admin, format($q$SELECT public.message_photo_visible(%L)::text$q$, _m2::text || '/m11-probe.webp'));
  IF _r <> 'ok true' THEN _fail := _fail || ('D6 admin cannot open a chat photo: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT public.message_photo_visible(%L)::text$q$, _m2::text || '/m11-probe.webp'));
  IF _r <> 'ok false' THEN _fail := _fail || ('D6 an outsider can open a chat photo: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_photo_visible(%L)::text$q$, _m2::text || '/m11-probe.webp'));
  IF _r <> 'ok true' THEN _fail := _fail || ('D6 a chat member cannot open the photo: ' || _r); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M11 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M11 PASS — admin sees exactly what the member sees, writes nothing, member table searchable/sortable/pageable, photos open for admins';
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3200 — M22 read receipts off + admin chat views. One transaction, ROLLBACK.
-- Before 20261118_3200: FAIL (message_admin_views missing). After: M22 PASS.
--   P1  receiver has read the message, read_receipts on  → the sender sees 'read'
--   P2  same, receiver sets read_receipts = off          → the sender sees 'delivered' (never 'read')
--   P3  an admin opening a chat writes ONE view row; again within 10 minutes writes none; an older page writes none
--   P4  members and visitors cannot read or write the views table
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
  _m1 uuid; _m2 uuid; _admin uuid; _conv uuid; _tick text; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M22 lane %', current_setting('p32.lane', true);

  IF to_regclass('public.message_admin_views') IS NULL THEN
    RAISE EXCEPTION 'M22 FAIL: message_admin_views missing — expected before 20261118_3200';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r JOIN auth.users u ON u.id = r.user_id WHERE r.role::text = 'admin' ORDER BY r.user_id LIMIT 1;
  IF _m2 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M22 FAIL: need two members and one admin to test with'; END IF;

  INSERT INTO public.conversations (kind, direct_key, created_by, last_message_at)
    VALUES ('direct', least(_m1::text, _m2::text) || ':' || greatest(_m1::text, _m2::text) || ':m22', _m1, now()) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, folder, joined_at, last_delivered_at, last_read_at)
    VALUES (_conv, _m1, 'inbox', now() - interval '2 hours', now() - interval '5 minutes', now() - interval '5 minutes'),
           (_conv, _m2, 'inbox', now() - interval '2 hours', now() - interval '5 minutes', now() - interval '5 minutes');
  INSERT INTO public.messages (conversation_id, sender_id, body, client_msg_id, created_at) VALUES (_conv, _m1, 'M22 hello', gen_random_uuid(), now() - interval '30 minutes');

  -- P1 / P2
  UPDATE public.profiles SET privacy_settings = coalesce(privacy_settings, '{}'::jsonb) - 'read_receipts' WHERE id = _m2;
  PERFORM pg_temp.set_user(_m1);
  _tick := public.message_thread(_conv) -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'read' THEN _fail := _fail || ('P1 with receipts on the sender should see read, saw ' || coalesce(_tick, 'null')); END IF;
  UPDATE public.profiles SET privacy_settings = coalesce(privacy_settings, '{}'::jsonb) || '{"read_receipts":"off"}'::jsonb WHERE id = _m2;
  _tick := public.message_thread(_conv) -> 0 ->> 'tick';
  IF _tick IS DISTINCT FROM 'delivered' THEN _fail := _fail || ('P2 with receipts off the sender should see delivered, saw ' || coalesce(_tick, 'null')); END IF;
  UPDATE public.profiles SET privacy_settings = coalesce(privacy_settings, '{}'::jsonb) - 'read_receipts' WHERE id = _m2;

  -- P3 (admin: member _m1's view of the chat)
  PERFORM pg_temp.set_user(_admin);
  PERFORM public.admin_view_thread(_m1, _conv);
  PERFORM public.admin_view_thread(_m1, _conv);
  SELECT count(*) INTO _n FROM public.message_admin_views WHERE admin_id = _admin AND conversation_id = _conv;
  IF _n <> 1 THEN _fail := _fail || ('P3 expected 1 view row after two opens, found ' || _n); END IF;
  PERFORM public.admin_view_thread(_m1, _conv, 999999999);
  SELECT count(*) INTO _n FROM public.message_admin_views WHERE admin_id = _admin AND conversation_id = _conv;
  IF _n <> 1 THEN _fail := _fail || ('P3 an older page wrote a view row: ' || _n); END IF;
  UPDATE public.message_admin_views SET at = now() - interval '11 minutes' WHERE admin_id = _admin AND conversation_id = _conv;
  PERFORM public.admin_view_thread(_m1, _conv);
  SELECT count(*) INTO _n FROM public.message_admin_views WHERE admin_id = _admin AND conversation_id = _conv;
  IF _n <> 2 THEN _fail := _fail || ('P3 an open after 10 minutes should add a row, found ' || _n); END IF;

  -- P4
  IF has_table_privilege('authenticated', 'public.message_admin_views', 'SELECT') OR has_table_privilege('authenticated', 'public.message_admin_views', 'INSERT')
     OR has_table_privilege('anon', 'public.message_admin_views', 'SELECT') OR has_table_privilege('anon', 'public.message_admin_views', 'INSERT')
  THEN _fail := _fail || 'P4 a member or visitor can reach message_admin_views'; END IF;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M22 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M22 PASS — read receipts off shows delivered only; admin chat opens are recorded once per 10 minutes, nobody else can see them';
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_2100 — M10 automatic guard + reports. One transaction, ROLLBACK.
-- Before 20261118_2100: FAIL (message_report missing). After: M10 PASS.
-- Supersedes the 'hold' checks of PROBE_1400 (hold no longer exists).
--   C1  no hold rules left, political starter rules off, 'hold' refused by the table and by word_add
--   C2  a blocked word is refused through the real door (MSG-060); a clean message goes through
--   C3  a new account cannot send a link (MSG-061); an older account can
--   C4  a member reports a chat; outsiders / bad reasons refused; one open report per chat; the member cannot read reports
--   C5  admin reads the reports and the watch list, closes a report
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
  _r text; _n int; _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _res jsonb; _conv uuid; _rid bigint; _rep uuid;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M10 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_report(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'M10 FAIL: message_report missing — expected before 20261118_2100';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' LIMIT 1;
  IF _m3 IS NULL OR _admin IS NULL THEN RAISE EXCEPTION 'M10 FAIL: need three members and one admin to test with'; END IF;

  -- C1 no hold
  SELECT count(*) INTO _n FROM public.message_word_rules WHERE action = 'hold';
  IF _n <> 0 THEN _fail := _fail || ('C1 ' || _n || ' hold rules left'); END IF;
  SELECT count(*) INTO _n FROM public.message_word_rules WHERE category = 'political' AND active;
  IF _n <> 0 THEN _fail := _fail || ('C1 ' || _n || ' political starter rules still on'); END IF;
  BEGIN INSERT INTO public.message_word_rules (category, pattern, action) VALUES ('abuse', 'zzprobe', 'hold'); _fail := _fail || 'C1 table accepted hold';
  EXCEPTION WHEN check_violation THEN NULL; END;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  BEGIN PERFORM public.message_admin_word_add('abuse', 'zzprobe', 'en', 'hold', 'M10 probe'); _fail := _fail || 'C1 word_add accepted hold';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);

  -- setup for the door: m1 may message and follows m2 (a clean inbox send); m3 is only used for reports
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2) AND following_id IN (_m1, _m2);
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_selected';
  INSERT INTO public.message_control_members (user_id) VALUES (_m1);
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2), (_m2, _m1);
  UPDATE public.profiles SET created_at = now() - interval '60 days' WHERE id = _m1;

  -- C2 blocked word / clean message
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'you are a bastard', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'refused 42501 MSG-060%' THEN _fail := _fail || ('C2 blocked word not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'lovely light in your last frame', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('C2 clean message refused: ' || _r); END IF;

  -- C3 links
  UPDATE public.profiles SET created_at = now() - interval '1 day' WHERE id = _m1;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'see www.example.com for more', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'refused 42501 MSG-061%' THEN _fail := _fail || ('C3 new account sent a link: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'my shot at the 50mm lens, f/1.8', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('C3 new account blocked without a link: ' || _r); END IF;
  UPDATE public.profiles SET created_at = now() - interval '60 days' WHERE id = _m1;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'see https://example.com/shot', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('C3 older account could not send a link: ' || _r); END IF;

  -- C4 reports (the chat is created directly: as_user work is rolled back)
  INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', least(_m2::text, _m3::text) || ':' || greatest(_m2::text, _m3::text), _m2) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id) VALUES (_conv, _m2), (_conv, _m3);
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_report(%L, 'spam', NULL)::text$q$, _conv));
  IF _r NOT LIKE 'refused 42501 MSG-071%' THEN _fail := _fail || ('C4 outsider reported: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, format($q$SELECT public.message_report(%L, 'weird', NULL)::text$q$, _conv));
  IF _r NOT LIKE 'refused 22023 MSG-070%' THEN _fail := _fail || ('C4 bad reason accepted: ' || _r); END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m2, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _m2::text, true);
  IF NOT public.message_report(_conv, 'abuse', 'M10 probe') THEN _fail := _fail || 'C4 report returned false'; END IF;
  IF NOT public.message_report(_conv, 'abuse', 'again') THEN _fail := _fail || 'C4 second report returned false'; END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  SELECT count(*) INTO _n FROM public.message_reports WHERE conversation_id = _conv AND reporter_id = _m2;
  IF _n <> 1 THEN _fail := _fail || ('C4 expected 1 open report, got ' || _n); END IF;
  SELECT reported_user_id INTO _rep FROM public.message_reports WHERE conversation_id = _conv;
  IF _rep IS DISTINCT FROM _m3 THEN _fail := _fail || 'C4 reported member wrong'; END IF;
  _r := pg_temp.as_user(_m2, $q$SELECT public.admin_message_reports('open')::text$q$);
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('C4 member read the reports: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, 'SELECT public.admin_message_watchlist()::text');
  IF _r NOT LIKE 'refused 42501 MSGADM-001%' THEN _fail := _fail || ('C4 member read the watch list: ' || _r); END IF;

  -- C5 admin
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _admin::text, true);
  _res := public.admin_message_reports('open');
  IF jsonb_array_length(_res) < 1 OR (_res -> 0 ->> 'reason') IS NULL THEN _fail := _fail || 'C5 admin saw no reports'; END IF;
  IF jsonb_array_length(public.admin_message_watchlist()) < 1 THEN _fail := _fail || 'C5 watch list empty'; END IF;
  SELECT id INTO _rid FROM public.message_reports WHERE conversation_id = _conv;
  IF NOT public.admin_message_report_done(_rid, 'checked') THEN _fail := _fail || 'C5 close returned false'; END IF;
  IF public.admin_message_report_done(_rid, 'again') THEN _fail := _fail || 'C5 closed twice'; END IF;
  IF jsonb_array_length(public.admin_message_reports('open')) <> 0 THEN _fail := _fail || 'C5 closed report still open'; END IF;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M10 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M10 PASS — no hold, blocked words refused, new accounts no links, member reports, admin reports + watch list';
END
$p$;

ROLLBACK;

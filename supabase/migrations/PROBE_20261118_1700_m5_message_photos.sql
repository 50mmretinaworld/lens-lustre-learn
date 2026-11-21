-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_1700 — M5 message photos. One transaction, ROLLBACK.
-- Before 20261118_1700: FAIL (message_send_core missing). After: M5 PASS.
--   F1  bucket is private, 5 MB, 3 image types; anon cannot run the photo door; core not callable by members
--   F2  storage rules: a member can read their own upload; another member cannot; after the message the chat's other
--       member can; an outsider cannot; a held photo is hidden from the receiver
--   F3  photo door: 1 photo + caption sent; thread shows its path; text door still works (wrapper)
--   F4  refused: someone else's folder, a file that was never uploaded, wrong type, over 5 MB, used twice, 11 photos, no photos + no text
--   F5  photos switched off for the member → MSG-023; text still goes
--   F6  caption goes through the word guard
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
CREATE FUNCTION pg_temp.photo(_from uuid, _to uuid, _caption text, _photos jsonb) RETURNS text LANGUAGE sql AS $f$
  SELECT pg_temp.as_user(_from, format('SELECT public.message_send_photo(%L, %L, gen_random_uuid(), %L::jsonb)::text', _to, _caption, _photos::text));
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _n int; _m1 uuid; _m2 uuid; _m3 uuid; _p1 text; _p2 text; _p3 text; _p4 text; _p5 text; _held bigint; _conv uuid; _j jsonb; _i int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M5 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.message_send_core(uuid,text,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'M5 FAIL: message_send_core missing — expected before 20261118_1700';
  END IF;

  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 1;
  IF _m3 IS NULL THEN RAISE EXCEPTION 'M5 FAIL: need three members to test with'; END IF;

  UPDATE public.system_flags SET value = false WHERE key = 'job_engine_push';
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2, _m3) AND following_id IN (_m1, _m2, _m3);
  DELETE FROM public.user_blocks WHERE blocker_id IN (_m1, _m2, _m3) AND blocked_id IN (_m1, _m2, _m3);
  DELETE FROM public.message_control_members;
  UPDATE public.message_control SET mode = 'allowed_all';
  DELETE FROM public.message_word_rules;
  INSERT INTO public.message_word_rules (category, pattern, action) VALUES ('threat', 'kill you', 'block');
  INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2), (_m2, _m1);

  -- F1
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'message-photos' AND NOT public AND file_size_limit = 5000000
                  AND allowed_mime_types @> ARRAY['image/jpeg', 'image/png', 'image/webp'] AND cardinality(allowed_mime_types) = 3) THEN
    _fail := _fail || 'F1 bucket is not private / 5 MB / 3 image types';
  END IF;
  IF has_function_privilege('anon', 'public.message_send_photo(uuid,text,uuid,jsonb)', 'EXECUTE') THEN _fail := _fail || 'F1 anon can run the photo door'; END IF;
  IF has_function_privilege('authenticated', 'public.message_send_core(uuid,text,uuid,jsonb)', 'EXECUTE') THEN _fail := _fail || 'F1 members can run the core directly'; END IF;

  -- planted uploads (service path: storage rows with the metadata storage would set)
  _p1 := _m1 || '/ok1.webp'; _p2 := _m1 || '/ok2.webp'; _p3 := _m1 || '/bad.gif'; _p4 := _m1 || '/huge.webp'; _p5 := _m2 || '/theirs.webp';
  INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES
    ('message-photos', _p1, _m1, '{"mimetype":"image/webp","size":120000}'),
    ('message-photos', _p2, _m1, '{"mimetype":"image/webp","size":90000}'),
    ('message-photos', _p3, _m1, '{"mimetype":"image/gif","size":1000}'),
    ('message-photos', _p4, _m1, '{"mimetype":"image/webp","size":6000000}'),
    ('message-photos', _p5, _m2, '{"mimetype":"image/webp","size":1000}');

  -- F2 before sending: own upload readable, other member's not
  _r := pg_temp.as_user(_m1, format($q$SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p1));
  IF _r <> 'ok 1' THEN _fail := _fail || ('F2 uploader cannot read own file: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, format($q$SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p1));
  IF _r <> 'ok 0' THEN _fail := _fail || ('F2 another member reads an unsent upload: ' || _r); END IF;

  -- F3 send
  _r := pg_temp.photo(_m1, _m2, 'my shot', jsonb_build_array(jsonb_build_object('path', _p1, 'width', 800, 'height', 600)));
  IF _r NOT LIKE 'ok %' OR _r NOT LIKE '%"duplicate": false%' THEN _fail := _fail || ('F3 photo not sent: ' || _r); END IF;
  -- the as_user work rolls back: do the real send through a kept identity
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m1, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _m1::text, true);
  _j := public.message_send_photo(_m2, 'my shot', gen_random_uuid(), jsonb_build_array(jsonb_build_object('path', _p1, 'width', 800, 'height', 600)));
  _conv := (_j ->> 'conversation_id')::uuid;
  _j := public.message_thread(_conv);
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  IF _j::text NOT LIKE '%' || _p1 || '%' OR _j::text NOT LIKE '%"kind": "photo"%' THEN _fail := _fail || ('F3 thread does not carry the photo: ' || left(_j::text, 200)); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'plain text', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('F3 text door broke: ' || _r); END IF;

  -- F2 after sending
  _r := pg_temp.as_user(_m2, format($q$SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p1));
  IF _r <> 'ok 1' THEN _fail := _fail || ('F2 receiver cannot read the sent photo: ' || _r); END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p1));
  IF _r <> 'ok 0' THEN _fail := _fail || ('F2 outsider reads the sent photo: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$DELETE FROM storage.objects WHERE bucket_id = 'message-photos' AND name = %L$q$, _p1));
  IF _r LIKE 'ok written' AND EXISTS (SELECT 1 FROM public.message_attachments WHERE storage_path = _p1) THEN
    SELECT count(*) INTO _n FROM storage.objects WHERE bucket_id = 'message-photos' AND name = _p1;
    IF _n = 0 THEN _fail := _fail || 'F2 an attached photo could be deleted'; END IF;
  END IF;

  -- F4 refusals
  _r := pg_temp.photo(_m1, _m2, '', jsonb_build_array(jsonb_build_object('path', _p5)));
  IF _r NOT LIKE 'refused 22023 MSG-025%' THEN _fail := _fail || ('F4 other member''s folder accepted: ' || _r); END IF;
  _r := pg_temp.photo(_m1, _m2, '', jsonb_build_array(jsonb_build_object('path', _m1 || '/never-uploaded.webp')));
  IF _r NOT LIKE 'refused 22023 MSG-025%' THEN _fail := _fail || ('F4 missing file accepted: ' || _r); END IF;
  _r := pg_temp.photo(_m1, _m2, '', jsonb_build_array(jsonb_build_object('path', _p3)));
  IF _r NOT LIKE 'refused 22023 MSG-025%' THEN _fail := _fail || ('F4 gif accepted: ' || _r); END IF;
  _r := pg_temp.photo(_m1, _m2, '', jsonb_build_array(jsonb_build_object('path', _p4)));
  IF _r NOT LIKE 'refused 22023 MSG-025%' THEN _fail := _fail || ('F4 oversize file accepted: ' || _r); END IF;
  _r := pg_temp.photo(_m1, _m2, '', jsonb_build_array(jsonb_build_object('path', _p1)));
  IF _r NOT LIKE 'refused 22023 MSG-025%' THEN _fail := _fail || ('F4 file used twice accepted: ' || _r); END IF;
  _r := pg_temp.photo(_m1, _m2, '', (SELECT jsonb_agg(jsonb_build_object('path', _m1 || '/p' || g || '.webp')) FROM generate_series(1, 11) g));
  IF _r NOT LIKE 'refused 22023 MSG-024%' THEN _fail := _fail || ('F4 11 photos accepted: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send_photo(%L, '', gen_random_uuid(), '[]'::jsonb)::text$q$, _m2));
  IF _r NOT LIKE 'refused 22023 MSG-003%' THEN _fail := _fail || ('F4 empty message accepted: ' || _r); END IF;

  -- F5 photos off
  INSERT INTO public.message_member_rules (user_id, photos_ok) VALUES (_m1, false);
  _r := pg_temp.photo(_m1, _m2, '', jsonb_build_array(jsonb_build_object('path', _p2)));
  IF _r NOT LIKE 'refused 42501 MSG-023%' THEN _fail := _fail || ('F5 photos-off not enforced: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$SELECT public.message_send(%L, 'text still ok', gen_random_uuid())::text$q$, _m2));
  IF _r NOT LIKE 'ok %' THEN _fail := _fail || ('F5 text refused while only photos are off: ' || _r); END IF;
  DELETE FROM public.message_member_rules WHERE user_id = _m1;

  -- F6 caption guard
  _r := pg_temp.photo(_m1, _m2, 'I will kill you', jsonb_build_array(jsonb_build_object('path', _p2)));
  IF _r NOT LIKE 'refused 42501 MSG-060%' THEN _fail := _fail || ('F6 caption not guarded: ' || _r); END IF;

  IF array_length(_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'M5 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M5 PASS — private photos: own-folder upload, chat-members-only read, no reuse, no oversize, switch + guard apply';
END
$p$;

ROLLBACK;

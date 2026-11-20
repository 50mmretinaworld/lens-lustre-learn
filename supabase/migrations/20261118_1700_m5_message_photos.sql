-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1700 · M5 — photos in private messages (private bucket, 5-minute links)
-- Needs M1 + M2 + M2c. Owner: photos yes, with a per-member control (text vs photos).
--
-- PRIVATE FILES. Bucket 'message-photos': private, 5 MB, JPEG / PNG / WebP only.
--   * a member can UPLOAD only into their own folder <uid>/..., and only while the
--     account may act and the messages switch allows them;
--   * a member can READ a file only if it is their own not-yet-sent upload, or it is
--     attached to a message in a chat they belong to (never a held message that is
--     not theirs). Nobody can list the bucket. The app asks storage for a SIGNED
--     LINK that lasts 5 minutes; storage creates it only if that read rule passes;
--   * a member can delete their own upload only while it is not attached to a message
--     (no unsend). Nobody can overwrite.
--
-- ONE DOOR, NOW WITH PHOTOS. message_send_core(to, body, client_msg_id, photos jsonb)
-- is the full door of M2/M2c plus the photo checks; message_send (text) and
-- message_send_photo (text caption + photos) are thin wrappers. The core is not
-- callable from the API. New checks, first failure wins:
--   MSG-023 photos switched off for this member   MSG-024 1–10 photos, each {path,width,height}
--   MSG-025 a file is not yours / not uploaded / wrong type / too big / already used
--   MSG-053 more than 100 photo messages today (not for the official account)
-- Caption: optional for photos (0–4000 characters); the word guard reads it.
-- KNOWN GAP, recorded for M5b: storage records the type the browser DECLARED. The app
-- re-encodes every photo to WebP in the browser (which also drops location data);
-- a server-side check of the file's real first bytes needs an edge function.
--
-- Rollback: supabase/rollback/20261118_1700_m5_message_photos_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1700_m5_message_photos.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_admin_word_add(text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'M5-PRE-001: M2c (20261118_1400) is not applied';
  END IF;
  IF to_regprocedure('public.message_thread(uuid,bigint,integer)') IS NULL THEN
    RAISE EXCEPTION 'M5-PRE-003: M4 (20261118_1600) is not applied';
  END IF;
  IF to_regprocedure('public.message_send_core(uuid,text,uuid,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'M5-PRE-002: message_send_core already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. bucket + rules ──────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('message-photos', 'message-photos', false, 5000000, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 5000000, allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp'];

ALTER TABLE public.message_attachments ADD CONSTRAINT message_attachments_path_once UNIQUE (storage_path);

CREATE FUNCTION public.message_photo_visible(_path text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL AND (
    ((storage.foldername(_path))[1] = (SELECT auth.uid())::text)
    OR EXISTS (SELECT 1 FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
                WHERE a.storage_path = _path
                  AND public.is_conversation_member(m.conversation_id)
                  AND (m.status = 'sent' OR m.sender_id = (SELECT auth.uid()))));
$fn$;
REVOKE ALL ON FUNCTION public.message_photo_visible(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_photo_visible(text) TO authenticated, service_role;

CREATE POLICY "message-photos: upload to own folder" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'message-photos'
              AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
              AND public.account_can_act((SELECT auth.uid()))
              AND public.message_control_allows((SELECT auth.uid())));
CREATE POLICY "message-photos: read what you may see" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'message-photos' AND public.message_photo_visible(name));
CREATE POLICY "message-photos: delete own unsent upload" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'message-photos'
         AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
         AND NOT EXISTS (SELECT 1 FROM public.message_attachments a WHERE a.storage_path = name));

-- ── 2. the door, with photos ───────────────────────────────────────────────
CREATE FUNCTION public.message_send_core(_to uuid, _body text, _client_msg_id uuid, _photos jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me         uuid := auth.uid();
  _text       text := btrim(coalesce(_body, ''));
  _np         integer := CASE WHEN _photos IS NULL OR jsonb_typeof(_photos) <> 'array' THEN 0 ELSE jsonb_array_length(_photos) END;
  _kind       text;
  _admin      boolean;
  _rules      public.message_member_rules%ROWTYPE;
  _friend     boolean;
  _follows    boolean;
  _followback boolean;
  _folder     text;
  _key        text;
  _conv       uuid;
  _new_conv   boolean := false;
  _guard      text := 'ok';
  _status     text := 'sent';
  _msg        bigint;
  _dup        record;
  _limit      integer;
  _age_days   numeric;
  _ph         jsonb;
  _path       text;
  _obj        record;
BEGIN
  IF _me IS NULL THEN
    RAISE EXCEPTION 'MSG-001: sign in to send a message' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.account_can_act(_me) THEN
    RAISE EXCEPTION 'ACCOUNT_UNDER_REVIEW' USING ERRCODE = 'insufficient_privilege',
      DETAIL = 'Your account is under review', HINT = 'support@50mmretina.com';
  END IF;
  IF _to IS NULL OR _to = _me THEN
    RAISE EXCEPTION 'MSG-002: choose another member to message' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  _kind := CASE WHEN _np > 0 THEN 'photo' ELSE 'text' END;
  IF _client_msg_id IS NULL OR char_length(_text) > 4000 OR (_kind = 'text' AND _text = '') THEN
    RAISE EXCEPTION 'MSG-003: a message needs 1–4000 characters (or photos) and a message id' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _kind = 'photo' AND (_np > 10 OR EXISTS (SELECT 1 FROM jsonb_array_elements(_photos) e WHERE jsonb_typeof(e) <> 'object' OR coalesce(e ->> 'path', '') = '')) THEN
    RAISE EXCEPTION 'MSG-024: send 1–10 photos, each with a path' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT m.id, m.conversation_id INTO _dup FROM public.messages m WHERE m.sender_id = _me AND m.client_msg_id = _client_msg_id;
  IF FOUND THEN
    RETURN jsonb_build_object('message_id', _dup.id, 'conversation_id', _dup.conversation_id, 'duplicate', true);
  END IF;

  IF NOT public.message_control_allows(_me) THEN
    RAISE EXCEPTION 'MSG-010: messaging is not available for your account' USING ERRCODE = 'insufficient_privilege';
  END IF;
  _admin := public.has_role(_me, 'admin'::public.app_role);
  SELECT * INTO _rules FROM public.message_member_rules r WHERE r.user_id = _me;
  IF FOUND THEN
    IF _rules.blocked_until IS NOT NULL AND _rules.blocked_until > now() THEN
      RAISE EXCEPTION 'MSG-020: messaging is paused for your account until %', to_char(_rules.blocked_until, 'YYYY-MM-DD')
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF _kind = 'text' AND NOT _rules.text_ok THEN
      RAISE EXCEPTION 'MSG-021: text messages are not available for your account' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF _kind = 'photo' AND NOT _rules.photos_ok THEN
      RAISE EXCEPTION 'MSG-023: photos are not available for your account' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = _to) OR NOT public.account_can_act(_to) THEN
    RAISE EXCEPTION 'MSG-011: this member cannot receive messages' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF EXISTS (SELECT 1 FROM public.user_blocks b
              WHERE (b.blocker_id = _me AND b.blocked_id = _to) OR (b.blocker_id = _to AND b.blocked_id = _me)) THEN
    RAISE EXCEPTION 'MSG-030: you cannot message this member' USING ERRCODE = 'insufficient_privilege';
  END IF;

  _friend := EXISTS (SELECT 1 FROM public.friendships f WHERE f.status = 'accepted'
                      AND ((f.requester_id = _me AND f.addressee_id = _to) OR (f.requester_id = _to AND f.addressee_id = _me)));
  _follows    := EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = _me AND f.following_id = _to);
  _followback := EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = _to AND f.following_id = _me);
  IF coalesce(_rules.friends_only, false) AND NOT (_friend OR _admin) THEN
    RAISE EXCEPTION 'MSG-022: your account can message friends only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _admin OR _friend OR (_follows AND _followback) THEN
    _folder := 'inbox';
  ELSIF _follows THEN
    _folder := 'requests';
  ELSE
    RAISE EXCEPTION 'MSG-040: you can message members you follow and your friends' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT _admin THEN
    IF (SELECT count(*) FROM public.messages m WHERE m.sender_id = _me AND m.created_at > now() - interval '1 minute') >= 20 THEN
      RAISE EXCEPTION 'MSG-050: slow down — too many messages in a minute' USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT extract(epoch FROM (now() - p.created_at)) / 86400 INTO _age_days FROM public.profiles p WHERE p.id = _me;
    _limit := coalesce(_rules.daily_limit, CASE WHEN coalesce(_age_days, 0) < 7 THEN 50 ELSE 500 END);
    IF (SELECT count(*) FROM public.messages m WHERE m.sender_id = _me AND m.created_at > now() - interval '24 hours') >= _limit THEN
      RAISE EXCEPTION 'MSG-051: daily message limit reached' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF _kind = 'photo' AND (SELECT count(*) FROM public.messages m WHERE m.sender_id = _me AND m.kind = 'photo' AND m.created_at > now() - interval '24 hours') >= 100 THEN
      RAISE EXCEPTION 'MSG-053: daily photo limit reached' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- the files: yours, uploaded, right type and size, not used before
  IF _kind = 'photo' THEN
    FOR _ph IN SELECT e FROM jsonb_array_elements(_photos) e LOOP
      _path := _ph ->> 'path';
      IF _path !~ ('^' || _me::text || '/[A-Za-z0-9._-]+$') THEN
        RAISE EXCEPTION 'MSG-025: a photo is not in your upload folder' USING ERRCODE = 'invalid_parameter_value';
      END IF;
      SELECT o.metadata ->> 'mimetype' AS mime, (o.metadata ->> 'size')::bigint AS bytes INTO _obj
        FROM storage.objects o WHERE o.bucket_id = 'message-photos' AND o.name = _path;
      IF NOT FOUND OR _obj.mime NOT IN ('image/jpeg', 'image/png', 'image/webp') OR _obj.bytes IS NULL OR _obj.bytes < 1 OR _obj.bytes > 5000000 THEN
        RAISE EXCEPTION 'MSG-025: a photo is missing, the wrong type or too big' USING ERRCODE = 'invalid_parameter_value';
      END IF;
      IF EXISTS (SELECT 1 FROM public.message_attachments a WHERE a.storage_path = _path) THEN
        RAISE EXCEPTION 'MSG-025: a photo was already sent' USING ERRCODE = 'invalid_parameter_value';
      END IF;
    END LOOP;
  END IF;

  IF _text <> '' THEN
    _guard := public.message_word_guard(_me, _text);
  END IF;
  IF _guard = 'block' THEN
    RAISE EXCEPTION 'MSG-060: this message cannot be sent' USING ERRCODE = 'insufficient_privilege';
  ELSIF _guard = 'hold' THEN
    _status := 'held';
  END IF;

  _key := least(_me::text, _to::text) || ':' || greatest(_me::text, _to::text);
  SELECT c.id INTO _conv FROM public.conversations c WHERE c.direct_key = _key;
  IF _conv IS NULL THEN
    IF NOT _admin AND (SELECT count(*) FROM public.conversations c WHERE c.created_by = _me AND c.created_at > now() - interval '24 hours') >= 30 THEN
      RAISE EXCEPTION 'MSG-052: too many new chats today' USING ERRCODE = 'insufficient_privilege';
    END IF;
    INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', _key, _me)
    ON CONFLICT (direct_key) DO NOTHING RETURNING id INTO _conv;
    IF _conv IS NULL THEN
      SELECT c.id INTO _conv FROM public.conversations c WHERE c.direct_key = _key;
    ELSE
      _new_conv := true;
    END IF;
    INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conv, _me, 'owner', 'inbox') ON CONFLICT DO NOTHING;
    INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conv, _to, 'member', _folder) ON CONFLICT DO NOTHING;
  ELSIF _folder = 'inbox' THEN
    UPDATE public.conversation_members SET folder = 'inbox' WHERE conversation_id = _conv AND user_id = _to AND folder = 'requests';
  END IF;

  BEGIN
    INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id, status)
    VALUES (_conv, _me, _kind, _text, _client_msg_id, _status) RETURNING id INTO _msg;
  EXCEPTION WHEN unique_violation THEN
    SELECT m.id, m.conversation_id INTO _dup FROM public.messages m WHERE m.sender_id = _me AND m.client_msg_id = _client_msg_id;
    RETURN jsonb_build_object('message_id', _dup.id, 'conversation_id', _dup.conversation_id, 'duplicate', true);
  END;
  IF _kind = 'photo' THEN
    INSERT INTO public.message_attachments (message_id, storage_path, mime, bytes, width, height)
    SELECT _msg, e ->> 'path', o.metadata ->> 'mimetype', (o.metadata ->> 'size')::integer,
           nullif(e ->> 'width', '')::integer, nullif(e ->> 'height', '')::integer
      FROM jsonb_array_elements(_photos) e
      JOIN storage.objects o ON o.bucket_id = 'message-photos' AND o.name = e ->> 'path';
  END IF;
  IF _status = 'sent' THEN
    UPDATE public.conversations SET last_message_at = now() WHERE id = _conv;
  END IF;
  IF _guard = 'hold' THEN
    INSERT INTO public.message_guard_events (user_id, action, message_id) VALUES (_me, 'hold', _msg);
  END IF;

  RETURN jsonb_build_object('message_id', _msg, 'conversation_id', _conv, 'duplicate', false,
                            'status', _status, 'folder', _folder, 'new_chat', _new_conv, 'help', (_guard = 'help'));
END
$fn$;
REVOKE ALL ON FUNCTION public.message_send_core(uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_send_core(uuid, text, uuid, jsonb) TO service_role;

-- text door = the core with no photos
CREATE OR REPLACE FUNCTION public.message_send(_to uuid, _body text, _client_msg_id uuid)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT public.message_send_core(_to, _body, _client_msg_id, '[]'::jsonb); $fn$;

-- photo door: caption + 1–10 photos
CREATE FUNCTION public.message_send_photo(_to uuid, _caption text, _client_msg_id uuid, _photos jsonb)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT public.message_send_core(_to, _caption, _client_msg_id, coalesce(_photos, '[]'::jsonb)); $fn$;
REVOKE ALL ON FUNCTION public.message_send_photo(uuid, text, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_send_photo(uuid, text, uuid, jsonb) TO authenticated, service_role;

-- ── 3. the thread now carries each message's photos ────────────────────────
CREATE OR REPLACE FUNCTION public.message_thread(_conversation uuid, _before_id bigint DEFAULT NULL, _limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid());
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.conversation_members cm WHERE cm.conversation_id = _conversation AND cm.user_id = _me) THEN
    RAISE EXCEPTION 'MSG-071: not your chat' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', m.body,
                                        'created_at', m.created_at, 'status', CASE WHEN m.sender_id = _me THEN m.status ELSE 'sent' END,
                                        'photos', coalesce((SELECT jsonb_agg(jsonb_build_object('path', a.storage_path, 'width', a.width, 'height', a.height) ORDER BY a.created_at, a.id)
                                                              FROM public.message_attachments a WHERE a.message_id = m.id), '[]'::jsonb))
                     ORDER BY m.id DESC)
      FROM (SELECT * FROM public.messages m2
             WHERE m2.conversation_id = _conversation
               AND (m2.status = 'sent' OR (m2.sender_id = _me AND m2.status = 'held'))
               AND (_before_id IS NULL OR m2.id < _before_id)
             ORDER BY m2.id DESC LIMIT least(greatest(coalesce(_limit, 50), 1), 100)) m), '[]'::jsonb);
END
$fn$;

-- the two functions re-issued above keep their callers: signed-in members and the service role
REVOKE ALL ON FUNCTION public.message_send(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_send(uuid, text, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.message_thread(uuid, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_thread(uuid, bigint, integer) TO authenticated, service_role;

COMMIT;

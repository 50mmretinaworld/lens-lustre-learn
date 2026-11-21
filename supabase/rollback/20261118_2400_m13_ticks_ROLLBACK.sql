-- ROLLBACK · 20261118_2400 · M13 message ticks
-- Puts message_thread, admin_view_thread and message_mark_read back as they were (no "tick" field, read only),
-- and drops the delivery column and its two functions. Message data is untouched.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

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

CREATE OR REPLACE FUNCTION public.admin_view_thread(_user uuid, _conversation uuid, _before_id bigint DEFAULT NULL, _limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can open a message box' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _user IS NULL OR NOT EXISTS (SELECT 1 FROM public.conversation_members cm WHERE cm.conversation_id = _conversation AND cm.user_id = _user) THEN
    RAISE EXCEPTION 'MSG-071: not this member''s chat' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', m.body,
                                        'created_at', m.created_at, 'status', CASE WHEN m.sender_id = _user THEN m.status ELSE 'sent' END,
                                        'photos', coalesce((SELECT jsonb_agg(jsonb_build_object('path', a.storage_path, 'width', a.width, 'height', a.height) ORDER BY a.created_at, a.id)
                                                              FROM public.message_attachments a WHERE a.message_id = m.id), '[]'::jsonb))
                     ORDER BY m.id DESC)
      FROM (SELECT * FROM public.messages m2
             WHERE m2.conversation_id = _conversation
               AND (m2.status = 'sent' OR (m2.sender_id = _user AND m2.status = 'held'))
               AND (_before_id IS NULL OR m2.id < _before_id)
             ORDER BY m2.id DESC LIMIT least(greatest(coalesce(_limit, 50), 1), 100)) m), '[]'::jsonb);
END
$fn$;

CREATE OR REPLACE FUNCTION public.message_mark_read(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET last_read_at = now() WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid());
  RETURN FOUND;
END
$fn$;

CREATE OR REPLACE FUNCTION public.message_my_conversations(_folder text DEFAULT 'inbox', _limit integer DEFAULT 30, _before timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid());
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF _folder NOT IN ('inbox', 'requests') THEN
    RAISE EXCEPTION 'MSG-070: folder must be inbox or requests' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.sort_at DESC NULLS LAST) FROM (
      SELECT coalesce(c.last_message_at, c.created_at) AS sort_at,
             jsonb_build_object(
               'conversation_id', c.id, 'kind', c.kind, 'title', c.title, 'folder', cm.folder, 'muted', cm.muted,
               'last_message_at', c.last_message_at,
               'other', (SELECT jsonb_build_object('user_id', o.user_id, 'full_name', p.full_name, 'username', p.custom_url, 'avatar_url', p.avatar_url)
                           FROM public.conversation_members o LEFT JOIN public.profiles p ON p.id = o.user_id
                          WHERE o.conversation_id = c.id AND o.user_id <> _me ORDER BY o.joined_at LIMIT 1),
               'last', (SELECT jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', left(m.body, 200), 'created_at', m.created_at)
                          FROM public.messages m
                         WHERE m.conversation_id = c.id AND (m.status = 'sent' OR (m.sender_id = _me AND m.status = 'held'))
                         ORDER BY m.id DESC LIMIT 1),
               'unread', (SELECT count(*) FROM public.messages m
                           WHERE m.conversation_id = c.id AND m.sender_id <> _me AND m.status = 'sent'
                             AND m.created_at > coalesce(cm.last_read_at, cm.joined_at))
             ) AS j
        FROM public.conversation_members cm
        JOIN public.conversations c ON c.id = cm.conversation_id
       WHERE cm.user_id = _me AND cm.folder = _folder
         AND (_before IS NULL OR coalesce(c.last_message_at, c.created_at) < _before)
         AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = 'sent' OR m.sender_id = _me))
       ORDER BY coalesce(c.last_message_at, c.created_at) DESC
       LIMIT least(greatest(coalesce(_limit, 30), 1), 100)
    ) x), '[]'::jsonb);
END
$fn$;

CREATE OR REPLACE FUNCTION public.admin_view_inbox(_user uuid, _folder text DEFAULT 'inbox', _limit integer DEFAULT 30, _before timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can open a message box' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _user IS NULL THEN
    RAISE EXCEPTION 'MSGADM-004: no such member' USING ERRCODE = 'no_data_found';
  END IF;
  IF _folder NOT IN ('inbox', 'requests') THEN
    RAISE EXCEPTION 'MSG-070: folder must be inbox or requests' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.sort_at DESC NULLS LAST) FROM (
      SELECT coalesce(c.last_message_at, c.created_at) AS sort_at,
             jsonb_build_object(
               'conversation_id', c.id, 'kind', c.kind, 'title', c.title, 'folder', cm.folder, 'muted', cm.muted,
               'last_message_at', c.last_message_at,
               'other', (SELECT jsonb_build_object('user_id', o.user_id, 'full_name', p.full_name, 'username', p.custom_url, 'avatar_url', p.avatar_url)
                           FROM public.conversation_members o LEFT JOIN public.profiles p ON p.id = o.user_id
                          WHERE o.conversation_id = c.id AND o.user_id <> _user ORDER BY o.joined_at LIMIT 1),
               'last', (SELECT jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', left(m.body, 200), 'created_at', m.created_at)
                          FROM public.messages m
                         WHERE m.conversation_id = c.id AND (m.status = 'sent' OR (m.sender_id = _user AND m.status = 'held'))
                         ORDER BY m.id DESC LIMIT 1),
               'unread', (SELECT count(*) FROM public.messages m
                           WHERE m.conversation_id = c.id AND m.sender_id <> _user AND m.status = 'sent'
                             AND m.created_at > coalesce(cm.last_read_at, cm.joined_at))
             ) AS j
        FROM public.conversation_members cm
        JOIN public.conversations c ON c.id = cm.conversation_id
       WHERE cm.user_id = _user AND cm.folder = _folder
         AND (_before IS NULL OR coalesce(c.last_message_at, c.created_at) < _before)
         AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = 'sent' OR m.sender_id = _user))
       ORDER BY coalesce(c.last_message_at, c.created_at) DESC
       LIMIT least(greatest(coalesce(_limit, 30), 1), 100)
    ) x), '[]'::jsonb);
END
$fn$;
REVOKE ALL ON FUNCTION public.message_my_conversations(text, integer, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_view_inbox(uuid, text, integer, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_my_conversations(text, integer, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_view_inbox(uuid, text, integer, timestamptz) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.message_mark_delivered();
DROP FUNCTION IF EXISTS public.message_tick(uuid, uuid, timestamptz);
ALTER TABLE public.conversation_members DROP COLUMN IF EXISTS last_delivered_at;

REVOKE ALL ON FUNCTION public.message_thread(uuid, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_mark_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_thread(uuid, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_mark_read(uuid) TO authenticated, service_role;

COMMIT;

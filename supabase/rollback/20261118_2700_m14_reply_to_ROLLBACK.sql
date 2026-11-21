-- ROLLBACK · 20261118_2700 · M14 reply to one message
-- Puts message_thread / admin_view_thread back to the M13 shape (ticks, no "reply"), drops the reply door and the link.
-- Messages stay; only the quote link is lost.
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
                                        'tick', CASE WHEN m.sender_id = _me AND m.status = 'sent' THEN public.message_tick(_conversation, _me, m.created_at) END,
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
                                        'tick', CASE WHEN m.sender_id = _user AND m.status = 'sent' THEN public.message_tick(_conversation, _user, m.created_at) END,
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

DROP FUNCTION IF EXISTS public.message_send_reply(uuid, text, uuid, bigint, jsonb);
DROP INDEX IF EXISTS public.messages_reply_to_idx;
ALTER TABLE public.messages DROP COLUMN IF EXISTS reply_to_id;

REVOKE ALL ON FUNCTION public.message_thread(uuid, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_thread(uuid, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) TO authenticated, service_role;

COMMIT;

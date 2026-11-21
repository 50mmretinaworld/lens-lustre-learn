-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2700 · M14 — reply to one message (a quote), like WhatsApp
-- Owner order 21 Nov 2026: "reply on any sentence — one user asked 10 lines, another answers one of them".
--
--   messages.reply_to_id  — the message this one answers (same chat only; the answer stays if the original goes)
--   message_send_reply(to, body, client id, reply_to, photos) — ONE call = the normal send door
--       (message_send_core: every rule, word guard, limit and dedupe unchanged) + the reply link, in one transaction.
--       A reply to a message that is not in this chat, or is held / not yours to see, refuses the whole send.
--   message_thread / admin_view_thread carry "reply": {id, sender_id, body (first 140 characters), photo} or null.
--       The admin's view stays byte-identical to the member's (PROBE 2200 D3).
--
-- Rollback: supabase/rollback/20261118_2700_m14_reply_to_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2700_m14_reply_to.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_tick(uuid,uuid,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'M14-PRE-001: M13 (20261118_2400) is not applied';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'messages' AND column_name = 'reply_to_id') THEN
    RAISE EXCEPTION 'M14-PRE-002: messages.reply_to_id already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. the link ────────────────────────────────────────────────────────────
ALTER TABLE public.messages ADD COLUMN reply_to_id bigint REFERENCES public.messages (id) ON DELETE SET NULL;
-- P28: messages · only the replies (a small fraction of messages) · the FK, and finding a message's answers
CREATE INDEX messages_reply_to_idx ON public.messages (reply_to_id) WHERE reply_to_id IS NOT NULL;

-- ── 2. send with a reply: the normal door, then the link, in one transaction ───
CREATE FUNCTION public.message_send_reply(_to uuid, _body text, _client_msg_id uuid, _reply_to bigint, _photos jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me uuid := (SELECT auth.uid());
  _res jsonb;
  _conv uuid;
  _mid bigint;
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in to send a message' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF _reply_to IS NULL THEN RAISE EXCEPTION 'MSG-080: say which message you are replying to' USING ERRCODE = 'invalid_parameter_value'; END IF;
  _res := public.message_send_core(_to, _body, _client_msg_id, coalesce(_photos, '[]'::jsonb));
  _conv := (_res ->> 'conversation_id')::uuid;
  _mid  := (_res ->> 'message_id')::bigint;
  -- the answered message must be in THIS chat and one this member may see (stored, or their own)
  IF NOT EXISTS (SELECT 1 FROM public.messages r
                  WHERE r.id = _reply_to AND r.conversation_id = _conv AND (r.status = 'sent' OR r.sender_id = _me)) THEN
    RAISE EXCEPTION 'MSG-080: that message is not in this chat' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  UPDATE public.messages SET reply_to_id = _reply_to WHERE id = _mid AND sender_id = _me AND reply_to_id IS NULL AND id <> _reply_to;
  RETURN _res;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_send_reply(uuid, text, uuid, bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_send_reply(uuid, text, uuid, bigint, jsonb) TO authenticated, service_role;

-- ── 3. the thread shows the quote (member's own, and the admin's identical view) ──
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
                                        'reply', (SELECT jsonb_build_object('id', r.id, 'sender_id', r.sender_id, 'body', left(r.body, 140),
                                                                             'photo', EXISTS (SELECT 1 FROM public.message_attachments ra WHERE ra.message_id = r.id))
                                                    FROM public.messages r WHERE r.id = m.reply_to_id AND r.conversation_id = m.conversation_id AND r.status = 'sent'),
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
                                        'reply', (SELECT jsonb_build_object('id', r.id, 'sender_id', r.sender_id, 'body', left(r.body, 140),
                                                                             'photo', EXISTS (SELECT 1 FROM public.message_attachments ra WHERE ra.message_id = r.id))
                                                    FROM public.messages r WHERE r.id = m.reply_to_id AND r.conversation_id = m.conversation_id AND r.status = 'sent'),
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

REVOKE ALL ON FUNCTION public.message_thread(uuid, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_thread(uuid, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) TO authenticated, service_role;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_3800 · M29 — export one chat for a legal request + close four unused admin functions (Owner list 21 Nov 2026)
--
--  1. admin_message_export(member, conversation): admin only. Returns the whole chat as one JSON document — who is in it, every
--     message (text, kind, time, status, photos with their storage paths, the message it answers) — capped at 20,000 messages
--     (the answer says if it was cut). Each export is recorded in message_admin_views (who, which chat, when), no dedupe.
--  2. Four admin functions nobody calls any more (checked: no client, no edge function, no job) are CLOSED — EXECUTE is taken
--     from members and visitors; the functions stay in the database so the step can be undone with one GRANT:
--        admin_message_member_chats · admin_read_conversation · admin_message_held_queue · admin_message_review
--     The old rogue-admin alarm (message_admin_alarm_eval) is left alone: nothing writes the table it counts any more, so it
--     never fires, and the daily maintenance still calls it.
--
-- Rollback: supabase/rollback/20261118_3800_m29_chat_export_and_close_unused_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_3800_m29_chat_export_and_close_unused.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_admin_views') IS NULL THEN
    RAISE EXCEPTION 'M29-PRE-001: M22 (20261118_3200) is not applied';
  END IF;
  IF to_regprocedure('public.admin_message_export(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'M29-PRE-002: admin_message_export already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

CREATE FUNCTION public.admin_message_export(_user uuid, _conversation uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := (SELECT auth.uid());
  _conv public.conversations;
  _total integer;
  _out jsonb;
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can export a chat' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _user IS NULL OR NOT EXISTS (SELECT 1 FROM public.conversation_members cm WHERE cm.conversation_id = _conversation AND cm.user_id = _user) THEN
    RAISE EXCEPTION 'MSG-071: not this member''s chat' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO _conv FROM public.conversations WHERE id = _conversation;
  SELECT count(*) INTO _total FROM public.messages WHERE conversation_id = _conversation;
  INSERT INTO public.message_admin_views (admin_id, member_id, conversation_id) VALUES (_uid, _user, _conversation);
  SELECT jsonb_build_object(
    'exported_at', now(),
    'exported_by', _uid,
    'conversation', jsonb_build_object('id', _conv.id, 'kind', _conv.kind, 'title', _conv.title, 'created_at', _conv.created_at),
    'members', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', cm.user_id, 'role', cm.role, 'full_name', p.full_name, 'username', p.custom_url, 'joined_at', cm.joined_at) ORDER BY cm.joined_at)
                           FROM public.conversation_members cm LEFT JOIN public.profiles p ON p.id = cm.user_id WHERE cm.conversation_id = _conversation), '[]'::jsonb),
    'message_count', _total,
    'truncated', _total > 20000,
    'messages', coalesce((SELECT jsonb_agg(x.j ORDER BY x.id) FROM (
        SELECT m.id, jsonb_build_object('id', m.id, 'created_at', m.created_at, 'sender_id', m.sender_id, 'sender_name', p.full_name, 'kind', m.kind, 'status', m.status,
                 'body', m.body, 'reply_to_id', m.reply_to_id,
                 'photos', coalesce((SELECT jsonb_agg(jsonb_build_object('path', a.storage_path, 'mime', a.mime, 'width', a.width, 'height', a.height, 'removed', a.expired_at IS NOT NULL) ORDER BY a.created_at, a.id)
                                       FROM public.message_attachments a WHERE a.message_id = m.id), '[]'::jsonb)) AS j
          FROM public.messages m LEFT JOIN public.profiles p ON p.id = m.sender_id
         WHERE m.conversation_id = _conversation ORDER BY m.id LIMIT 20000) x), '[]'::jsonb))
    INTO _out;
  RETURN _out;
END
$fn$;
REVOKE ALL ON FUNCTION public.admin_message_export(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_message_export(uuid, uuid) TO authenticated, service_role;

-- ── close four unused admin functions (reversible with GRANT) ──────────────
DO $close$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('admin_message_member_chats', 'admin_read_conversation', 'admin_message_held_queue', 'admin_message_review') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END
$close$;

COMMIT;

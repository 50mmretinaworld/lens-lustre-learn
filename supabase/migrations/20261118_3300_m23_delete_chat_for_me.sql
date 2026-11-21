-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_3300 · M23 — "Delete chat for me" (Owner list 21 Nov 2026)
--
-- A member clears a chat from THEIR side only. conversation_members.cleared_at = the moment they cleared it; their thread and
-- inbox then show only messages newer than that, and a chat with nothing newer drops out of their list. A new message revives
-- the chat with just the new messages. The other member is not told and keeps everything. Messages themselves are never
-- deleted (they are immutable by design, and the admin viewer still sees the full history for safety and legal needs).
--   message_clear_chat(conversation)      → members only; sets cleared_at and marks the chat read
--   message_thread / message_my_conversations patched in place (one condition each)
--
-- Rollback: supabase/rollback/20261118_3300_m23_delete_chat_for_me_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_3300_m23_delete_chat_for_me.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_can_reach(uuid)') IS NULL THEN
    RAISE EXCEPTION 'M23-PRE-001: 20261118_2910 is not applied';
  END IF;
  IF to_regprocedure('public.message_clear_chat(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'M23-PRE-002: message_clear_chat already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

ALTER TABLE public.conversation_members ADD COLUMN cleared_at timestamptz;

CREATE FUNCTION public.message_clear_chat(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  UPDATE public.conversation_members
     SET cleared_at = now(), last_read_at = now(), last_delivered_at = greatest(coalesce(last_delivered_at, now()), now())
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid());
  RETURN FOUND;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_clear_chat(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_clear_chat(uuid) TO authenticated, service_role;

DO $patch$
DECLARE
  _def text;
  _old1 constant text := 'AND (_before_id IS NULL OR m2.id < _before_id)';
  _new1 constant text := 'AND (_before_id IS NULL OR m2.id < _before_id)
               AND m2.created_at > coalesce((SELECT cx.cleared_at FROM public.conversation_members cx WHERE cx.conversation_id = _conversation AND cx.user_id = _me), ''-infinity''::timestamptz)';
  _old2 constant text := 'AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = ''sent'' OR m.sender_id = _me))';
  _new2 constant text := 'AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = ''sent'' OR m.sender_id = _me)
                       AND m.created_at > coalesce(cm.cleared_at, ''-infinity''::timestamptz))';
BEGIN
  _def := pg_get_functiondef('public.message_thread(uuid,bigint,integer)'::regprocedure);
  IF position(_old1 IN _def) = 0 THEN RAISE EXCEPTION 'M23-PRE-003: the paging line of message_thread was not found — nothing patched'; END IF;
  EXECUTE replace(_def, _old1, _new1);
  _def := pg_get_functiondef('public.message_my_conversations(text,integer,timestamptz)'::regprocedure);
  IF position(_old2 IN _def) = 0 THEN RAISE EXCEPTION 'M23-PRE-004: the has-messages line of message_my_conversations was not found — nothing patched'; END IF;
  EXECUTE replace(_def, _old2, _new2);
END
$patch$;

COMMIT;

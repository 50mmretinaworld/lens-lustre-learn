-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2500 · M13b — the live channel of one chat (typing dots + instant refresh)
-- Owner order 21 Nov 2026: "when typing show a typing animation".
--
--   The app opens a PRIVATE Realtime Broadcast channel named  chat:<conversation id>  while that chat is on
--   screen. Nothing is stored; the channel only carries two tiny events (typing, ping). Supabase asks the
--   database, for every join and every send, whether the member may use that topic: the two policies below
--   on realtime.messages answer with message_channel_member(topic) = "you are a member of that chat".
--   Anyone else (another member, a signed-out visitor, an admin who is only looking) is refused.
--   Presence and postgres_changes are NOT allowed on these topics; only 'broadcast'.
--
-- Rollback: supabase/rollback/20261118_2500_m13b_chat_channel_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2500_m13b_chat_channel.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('realtime.messages') IS NULL THEN
    RAISE EXCEPTION 'M13b-PRE-001: realtime.messages does not exist on this project';
  END IF;
  IF to_regprocedure('public.message_channel_member(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'M13b-PRE-002: message_channel_member already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. "is the signed-in member in the chat this topic names?" ─────────────
CREATE FUNCTION public.message_channel_member(_topic text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid());
BEGIN
  IF _me IS NULL OR _topic IS NULL THEN RETURN false; END IF;
  IF _topic !~ '^chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN false; END IF;
  RETURN EXISTS (SELECT 1 FROM public.conversation_members cm
                  WHERE cm.conversation_id = substr(_topic, 6)::uuid AND cm.user_id = _me AND cm.folder <> 'declined');
END
$fn$;
REVOKE ALL ON FUNCTION public.message_channel_member(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_channel_member(text) TO authenticated, service_role;

-- ── 2. who may listen and who may speak on a chat channel ──────────────────
CREATE POLICY messages_chat_channel_read ON realtime.messages
  FOR SELECT TO authenticated
  USING (realtime.messages.extension = 'broadcast' AND public.message_channel_member((SELECT realtime.topic())));

CREATE POLICY messages_chat_channel_write ON realtime.messages
  FOR INSERT TO authenticated
  WITH CHECK (realtime.messages.extension = 'broadcast' AND public.message_channel_member((SELECT realtime.topic())));

COMMIT;

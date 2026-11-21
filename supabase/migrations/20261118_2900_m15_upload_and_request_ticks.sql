-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2900 · M15 — two faults the Owner found on the live site (21 Nov 2026)
--
--  1. "That photo couldn't be sent."  The storage upload policy of the message-photos bucket (20261118_1700) called
--     account_can_act() and message_control_allows() directly. A row-security rule runs with the CALLER's rights, and
--     both functions are closed to members on purpose, so EVERY upload was refused ("permission denied for function").
--     My earlier PROBE tested the database door, never a real upload as a member. Now: one small function a member MAY
--     run (message_upload_allowed — answers only yes / no, about themselves), and the policy is re-made with it.
--
--  2. A request nobody accepted showed double BLUE ticks.  Opening a message request marked it read, and the sender saw
--     "read". Like Instagram: while the other person has NOT accepted (their folder is not the inbox) the sender sees ONE
--     tick (sent), nothing is marked read or delivered for them, and the request keeps counting as unread. Accepting moves
--     the chat to the inbox AND counts as reading it.
--
-- Rollback: supabase/rollback/20261118_2900_m15_upload_and_request_ticks_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2900_m15_upload_and_request_ticks.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_tick(uuid,uuid,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'M15-PRE-001: M13 (20261118_2400) is not applied';
  END IF;
  IF to_regprocedure('public.message_upload_allowed()') IS NOT NULL THEN
    RAISE EXCEPTION 'M15-PRE-002: message_upload_allowed already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. photo upload ────────────────────────────────────────────────────────
CREATE FUNCTION public.message_upload_allowed()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL
     AND public.account_can_act((SELECT auth.uid()))
     AND public.message_control_allows((SELECT auth.uid()));
$fn$;
REVOKE ALL ON FUNCTION public.message_upload_allowed() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_upload_allowed() TO authenticated, service_role;

DROP POLICY "message-photos: upload to own folder" ON storage.objects;
CREATE POLICY "message-photos: upload to own folder" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'message-photos'
              AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
              AND public.message_upload_allowed());

-- ── 2. requests: no "read", no "delivered" until the other person accepts ────
CREATE OR REPLACE FUNCTION public.message_tick(_conversation uuid, _sender uuid, _created timestamptz)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN count(*) = 0 THEN 'sent'
    WHEN bool_or(cm.folder <> 'inbox') THEN 'sent'                 -- a request (or a declined chat) the other person has not accepted
    WHEN bool_and(coalesce(cm.last_read_at, '-infinity'::timestamptz) >= _created) THEN 'read'
    WHEN bool_and(greatest(coalesce(cm.last_delivered_at, '-infinity'::timestamptz), coalesce(cm.last_read_at, '-infinity'::timestamptz)) >= _created) THEN 'delivered'
    ELSE 'sent' END
    FROM public.conversation_members cm
   WHERE cm.conversation_id = _conversation AND cm.user_id <> _sender
$fn$;
REVOKE ALL ON FUNCTION public.message_tick(uuid, uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_tick(uuid, uuid, timestamptz) TO service_role;

-- opening a request does not mark it read (it stays unread, and the sender keeps one tick)
CREATE OR REPLACE FUNCTION public.message_mark_read(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET last_read_at = now(), last_delivered_at = now()
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid()) AND folder = 'inbox';
  RETURN FOUND;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_mark_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_mark_read(uuid) TO authenticated, service_role;

-- accepting moves the chat to the inbox and counts as reading it
CREATE OR REPLACE FUNCTION public.message_accept_request(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET folder = 'inbox', last_read_at = now(), last_delivered_at = now()
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid()) AND folder IN ('requests', 'declined');
  RETURN FOUND;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_accept_request(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_accept_request(uuid) TO authenticated, service_role;

-- ── 3. "Active 12 m ago" (Owner 21 Nov: Meta style) ─────────────────────────
-- When a person is online the app knows it from the site's one presence channel. When they are not, this gives the last
-- time they were active — only for someone you share a chat with, and never for a member who switched "active status" off.
CREATE FUNCTION public.message_peer_status(_user uuid)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p.last_active_at
    FROM public.profiles p
   WHERE p.id = _user
     AND (SELECT auth.uid()) IS NOT NULL
     AND coalesce(p.privacy_settings ->> 'active_status', 'on') <> 'off'
     AND EXISTS (SELECT 1 FROM public.conversation_members a
                   JOIN public.conversation_members b ON b.conversation_id = a.conversation_id
                  WHERE a.user_id = (SELECT auth.uid()) AND b.user_id = _user);
$fn$;
REVOKE ALL ON FUNCTION public.message_peer_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_peer_status(uuid) TO authenticated, service_role;

COMMIT;

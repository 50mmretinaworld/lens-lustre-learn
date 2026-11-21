-- ROLLBACK · 20261118_2900 · M15 upload policy + request ticks
-- Puts message_tick / message_mark_read / message_accept_request back as they were after 2400, and the upload policy back
-- to the original (which calls the two closed functions directly — i.e. photo upload is broken again).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.message_tick(_conversation uuid, _sender uuid, _created timestamptz)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN count(*) = 0 THEN 'sent'
    WHEN bool_and(coalesce(cm.last_read_at, '-infinity'::timestamptz) >= _created) THEN 'read'
    WHEN bool_and(greatest(coalesce(cm.last_delivered_at, '-infinity'::timestamptz), coalesce(cm.last_read_at, '-infinity'::timestamptz)) >= _created) THEN 'delivered'
    ELSE 'sent' END
    FROM public.conversation_members cm
   WHERE cm.conversation_id = _conversation AND cm.user_id <> _sender
$fn$;
REVOKE ALL ON FUNCTION public.message_tick(uuid, uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_tick(uuid, uuid, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.message_mark_read(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET last_read_at = now(), last_delivered_at = now()
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid());
  RETURN FOUND;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_mark_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_mark_read(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.message_accept_request(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET folder = 'inbox'
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid()) AND folder IN ('requests', 'declined');
  RETURN FOUND;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_accept_request(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_accept_request(uuid) TO authenticated, service_role;

DROP POLICY IF EXISTS "message-photos: upload to own folder" ON storage.objects;
CREATE POLICY "message-photos: upload to own folder" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'message-photos'
              AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
              AND public.account_can_act((SELECT auth.uid()))
              AND public.message_control_allows((SELECT auth.uid())));
DROP FUNCTION IF EXISTS public.message_upload_allowed();
DROP FUNCTION IF EXISTS public.message_peer_status(uuid);

COMMIT;

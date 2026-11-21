-- ROLLBACK · 20261118_2200 · M11 admin opens a member's message box
-- Drops the three admin functions and puts the M7 photo rule back (admin: only within 10 minutes of a logged read).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.admin_message_member_search(text, text, text, text, integer, integer);
DROP FUNCTION IF EXISTS public.admin_view_thread(uuid, uuid, bigint, integer);
DROP FUNCTION IF EXISTS public.admin_view_inbox(uuid, text, integer, timestamptz);

CREATE OR REPLACE FUNCTION public.message_photo_visible(_path text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL AND (
    ((storage.foldername(_path))[1] = (SELECT auth.uid())::text)
    OR EXISTS (SELECT 1 FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
                WHERE a.storage_path = _path
                  AND public.is_conversation_member(m.conversation_id)
                  AND (m.status = 'sent' OR m.sender_id = (SELECT auth.uid())))
    OR (public.has_role((SELECT auth.uid()), 'admin'::public.app_role)
        AND EXISTS (SELECT 1 FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
                      JOIN public.message_admin_reads r ON r.conversation_id = m.conversation_id
                     WHERE a.storage_path = _path AND r.admin_id = (SELECT auth.uid()) AND r.at > now() - interval '10 minutes')));
$fn$;
REVOKE ALL ON FUNCTION public.message_photo_visible(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_photo_visible(text) TO authenticated, service_role;

COMMIT;

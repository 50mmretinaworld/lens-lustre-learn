-- ROLLBACK · 20261118_1700 · M5 message photos
-- Removes the photo door, the storage rules and the one-use constraint.
-- DELIBERATELY KEPT: message_send_core (with no photos it behaves exactly like the M2c door,
-- and message_send still calls it) and the 'message-photos' bucket with any files in it
-- (storage refuses SQL deletes of files; remove them from the dashboard if ever needed).
-- With the photo door and storage rules gone nobody can upload or read a message photo.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.message_send_photo(uuid, text, uuid, jsonb);
DROP POLICY IF EXISTS "message-photos: delete own unsent upload" ON storage.objects;
DROP POLICY IF EXISTS "message-photos: read what you may see" ON storage.objects;
DROP POLICY IF EXISTS "message-photos: upload to own folder" ON storage.objects;
DROP FUNCTION IF EXISTS public.message_photo_visible(text);
ALTER TABLE public.message_attachments DROP CONSTRAINT IF EXISTS message_attachments_path_once;

COMMIT;

-- ROLLBACK · 20261118_3500 · M25 photo verify
-- Stops the per-photo check. Photos already removed by the check stay removed (their files are deleted).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TRIGGER IF EXISTS message_attachments_verify_insert ON public.message_attachments;
DROP FUNCTION IF EXISTS public.message_attachments_verify();
DELETE FROM public.jobs WHERE kind = 'message.photo_verify' AND status = 'queued';
DELETE FROM public.job_kinds WHERE kind = 'message.photo_verify' AND NOT EXISTS (SELECT 1 FROM public.jobs j WHERE j.kind = 'message.photo_verify');
DROP FUNCTION IF EXISTS public.message_photo_verify_mark(uuid, boolean);
DROP FUNCTION IF EXISTS public.message_photo_to_verify(uuid);
ALTER TABLE public.message_attachments DROP COLUMN IF EXISTS checked_at;

COMMIT;

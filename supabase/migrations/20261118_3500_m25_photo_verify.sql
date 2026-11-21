-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_3500 · M25 — server check that a chat photo is really a photo (Owner list 21 Nov 2026)
--
-- Every chat photo gets one background check right after it is attached: the edge function message-photo-verify reads the
-- file's real first bytes (JPEG / PNG / WebP). A file that is not an image is deleted and its photo marked removed
-- (message_attachments.expired_at — the app then shows "Photo no longer available"); a good one is stamped checked_at.
--   message_attachments.checked_at              — set when the check passed
--   message_photo_to_verify(id)                 — service role: the path still to check (null when none / already checked)
--   message_photo_verify_mark(id, ok)           — service role: record the result (ok=false also marks the photo removed)
--   trigger message_attachments_verify          — AFTER INSERT: queues one job per photo (key photo-verify:<id>), only when the
--                                                 job engine is on; a fault here never blocks sending
--   job kind message.photo_verify               — edge:message-photo-verify, vault secret shared with push.send
-- Deploy order: edge function FIRST, then this SQL.
--
-- Rollback: supabase/rollback/20261118_3500_m25_photo_verify_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_3500_m25_photo_verify.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_photos_due(integer)') IS NULL THEN
    RAISE EXCEPTION 'M25-PRE-001: M19 (20261118_3100) is not applied';
  END IF;
  IF to_regprocedure('public.message_photo_to_verify(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'M25-PRE-002: message_photo_to_verify already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

ALTER TABLE public.message_attachments ADD COLUMN checked_at timestamptz;

CREATE FUNCTION public.message_photo_to_verify(_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT a.storage_path FROM public.message_attachments a WHERE a.id = _id AND a.checked_at IS NULL AND a.expired_at IS NULL;
$fn$;
REVOKE ALL ON FUNCTION public.message_photo_to_verify(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_photo_to_verify(uuid) TO service_role;

CREATE FUNCTION public.message_photo_verify_mark(_id uuid, _ok boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.message_attachments
     SET checked_at = now(), expired_at = CASE WHEN _ok THEN expired_at ELSE coalesce(expired_at, now()) END
   WHERE id = _id AND checked_at IS NULL;
  RETURN FOUND;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_photo_verify_mark(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_photo_verify_mark(uuid, boolean) TO service_role;

INSERT INTO public.job_kinds (kind, handler, max_attempts, backoff_seconds, timeout_seconds, max_running, extra_headers_secret, note)
VALUES ('message.photo_verify', 'edge:message-photo-verify', 3, ARRAY[60, 300], 60, 10, 'jobs:edge:send-push',
        'M25: one per chat photo (key photo-verify:<attachment id>); checks the real file signature, deletes a fake');

CREATE FUNCTION public.message_attachments_verify()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false) THEN
    BEGIN
      PERFORM public.job_start(public.job_enqueue('message.photo_verify', jsonb_build_object('attachment_id', NEW.id), 'photo-verify:' || NEW.id::text));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'message_attachments_verify: could not queue the check for attachment % (%)', NEW.id, SQLSTATE;
    END;
  END IF;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_attachments_verify() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER message_attachments_verify_insert AFTER INSERT ON public.message_attachments
  FOR EACH ROW EXECUTE FUNCTION public.message_attachments_verify();

COMMIT;

-- ROLLBACK · 20261118_1800 · M7 admin viewer / alarm / held review / wipe / retention
-- Restores the M1 / M5 versions of the two guard functions and the photo read rule,
-- removes every M7 function, the delete-log trigger, the job kind and its queued job.
-- message_files_purge is dropped only if empty (it may hold file paths awaiting purge).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TRIGGER IF EXISTS message_wipe_on_delete ON public.account_state_log;
DELETE FROM public.jobs WHERE kind = 'message.maintenance' AND status IN ('queued', 'cancelled');
DELETE FROM public.job_kinds WHERE kind = 'message.maintenance'
  AND NOT EXISTS (SELECT 1 FROM public.jobs j WHERE j.kind = 'message.maintenance');

DROP FUNCTION IF EXISTS public.message_maintenance(jsonb);
DROP FUNCTION IF EXISTS public.message_logs_trim();
DROP FUNCTION IF EXISTS public.message_wipe_on_delete_log();
DROP FUNCTION IF EXISTS public.message_wipe_member(uuid);
DROP FUNCTION IF EXISTS public.admin_message_review(bigint, boolean, text);
DROP FUNCTION IF EXISTS public.admin_message_held_queue();
DROP FUNCTION IF EXISTS public.admin_read_conversation(uuid, text, bigint, integer);
DROP FUNCTION IF EXISTS public.message_admin_alarm_eval();
DO $purge$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.message_files_purge) THEN DROP TABLE public.message_files_purge;
  ELSE RAISE NOTICE 'M7 rollback: message_files_purge kept — it still lists files to remove'; END IF;
END
$purge$;

-- the photo read rule as it was in M5 (members only)
CREATE OR REPLACE FUNCTION public.message_photo_visible(_path text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL AND (
    ((storage.foldername(_path))[1] = (SELECT auth.uid())::text)
    OR EXISTS (SELECT 1 FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
                WHERE a.storage_path = _path
                  AND public.is_conversation_member(m.conversation_id)
                  AND (m.status = 'sent' OR m.sender_id = (SELECT auth.uid()))));
$fn$;

REVOKE ALL ON FUNCTION public.message_photo_visible(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_photo_visible(text) TO authenticated, service_role;

-- the two guards as they were in M1
CREATE OR REPLACE FUNCTION public.message_log_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $fn$
BEGIN
  RAISE EXCEPTION '% is append-only (% refused)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
END
$fn$;
CREATE OR REPLACE FUNCTION public.messages_no_delete_no_unsend()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.status = 'held' AND NEW.status IN ('sent', 'rejected')
     AND (NEW.id, NEW.conversation_id, NEW.sender_id, NEW.kind, NEW.body, NEW.client_msg_id, NEW.created_at)
         IS NOT DISTINCT FROM (OLD.id, OLD.conversation_id, OLD.sender_id, OLD.kind, OLD.body, OLD.client_msg_id, OLD.created_at) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'MESSAGE_IMMUTABLE: messages cannot be edited, deleted or unsent' USING ERRCODE = 'insufficient_privilege';
END
$fn$;

DELETE FROM public.message_control_log WHERE area = 'review';   -- (service path; the trim exception is gone, so this is refused if any exist)
ALTER TABLE public.message_control_log DROP CONSTRAINT message_control_log_area_check;
ALTER TABLE public.message_control_log ADD CONSTRAINT message_control_log_area_check
  CHECK (area IN ('mode', 'groups', 'list', 'member_rule', 'word_rule'));

COMMIT;

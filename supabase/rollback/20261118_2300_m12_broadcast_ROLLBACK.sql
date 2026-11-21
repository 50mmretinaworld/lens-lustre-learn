-- ROLLBACK · 20261118_2300 · M12 broadcast
-- Drops the broadcast functions, tables and job kinds, puts the M3 push trigger function back and the UNIQUE
-- storage_path rule on message_attachments. Messages already delivered by a broadcast stay in the boxes.
-- Refuses to run while two attachments share a picture path (withdraw the broadcast first).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.message_attachments GROUP BY storage_path HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'M12-RB-001: broadcast pictures are still shared by several messages — withdraw those broadcasts first';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.admin_message_broadcast_recipients(bigint, text, text, integer, integer);
DROP FUNCTION IF EXISTS public.admin_message_broadcast_report(bigint);
DROP FUNCTION IF EXISTS public.admin_message_broadcasts(text, integer, integer);
DROP FUNCTION IF EXISTS public.admin_message_broadcast_withdraw(bigint);
DROP FUNCTION IF EXISTS public.admin_message_broadcast_control(bigint, text);
DROP FUNCTION IF EXISTS public.admin_message_broadcast_send(bigint, timestamptz);
DROP FUNCTION IF EXISTS public.admin_message_broadcast_audience(jsonb);
DROP FUNCTION IF EXISTS public.admin_message_broadcast_save(bigint, jsonb);
DROP FUNCTION IF EXISTS public.message_broadcast_withdraw_run(jsonb);
DROP FUNCTION IF EXISTS public.message_broadcast_run_batch(jsonb);
DROP FUNCTION IF EXISTS public.message_broadcast_roll_up(bigint);
DROP FUNCTION IF EXISTS public.message_broadcast_admin();

DELETE FROM public.jobs WHERE kind IN ('message.broadcast_batch', 'message.broadcast_withdraw') AND status IN ('queued', 'running');
DELETE FROM public.job_kinds WHERE kind IN ('message.broadcast_batch', 'message.broadcast_withdraw');

DROP TABLE IF EXISTS public.message_broadcast_recipients;
DROP TABLE IF EXISTS public.message_broadcast_batches;
DROP TABLE IF EXISTS public.message_broadcasts;

DROP INDEX IF EXISTS public.message_attachments_path_idx;
ALTER TABLE public.message_attachments ADD CONSTRAINT message_attachments_path_once UNIQUE (storage_path);

CREATE OR REPLACE FUNCTION public.messages_push()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _r      record;
  _name   text;
  _push   boolean;
BEGIN
  IF NEW.status <> 'sent' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status <> 'held' THEN RETURN NEW; END IF;
  IF NOT (coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false)
          AND coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine_push'), false)) THEN
    RETURN NEW;
  END IF;
  BEGIN
    SELECT coalesce(nullif(btrim(p.full_name), ''), 'Someone') INTO _name FROM public.profiles p WHERE p.id = NEW.sender_id;
    _name := coalesce(_name, 'Someone');
    FOR _r IN
      SELECT m.user_id, m.folder
        FROM public.conversation_members m
       WHERE m.conversation_id = NEW.conversation_id
         AND m.user_id <> NEW.sender_id
         AND NOT m.muted
         AND m.folder <> 'declined'
    LOOP
      SELECT coalesce((SELECT np.push_enabled FROM public.notification_preferences np WHERE np.user_id = _r.user_id), true) INTO _push;
      IF NOT _push THEN CONTINUE; END IF;
      PERFORM public.job_start(public.job_enqueue(
        'push.send',
        jsonb_build_object(
          'user_id', _r.user_id,
          'title', _name,
          'body', CASE WHEN _r.folder = 'requests' THEN 'sent you a message request' ELSE 'sent you a message' END,
          'data', jsonb_build_object('type', 'new_message', 'reference_id', NEW.conversation_id::text)),
        'message:' || NEW.id::text || ':' || _r.user_id::text));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'messages_push: could not queue the push for message % (%)', NEW.id, SQLSTATE;
  END;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.messages_push() FROM PUBLIC, anon, authenticated;

COMMIT;

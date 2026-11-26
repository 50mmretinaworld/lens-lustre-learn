-- Rollback of 20261126_6600: messages_push goes back to the 20261118_2300 version (fixed line, no message text).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

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
  IF coalesce(current_setting('messages.skip_push', true), '') = 'on' THEN RETURN NEW; END IF;
  IF NOT (coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false)
          AND coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine_push'), false)) THEN
    RETURN NEW;
  END IF;
  BEGIN
    IF public.has_role(NEW.sender_id, 'admin'::public.app_role) THEN
      _name := '50mm Retina World';
    ELSE
      SELECT coalesce(nullif(btrim(p.full_name), ''), 'Someone') INTO _name FROM public.profiles p WHERE p.id = NEW.sender_id;
      _name := coalesce(_name, 'Someone');
    END IF;
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

DELETE FROM public.system_flags WHERE key = 'message_push_text';

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261126_6600 · Message notification shows the message. Lanes: staging, production.
-- Owner 26 Nov 2026: "showing photo like instagram and msg when msg comes".
--   title = sender name (an admin shows as the brand, unchanged)
--   body  = the first 160 characters of the message · a photo without words: "sent a photo"
--   a message REQUEST (a stranger) still says only "sent you a message request"
--   DB switch system_flags.message_push_text: false → the old line "sent you a message" (no new build either way).
-- The text then sits in the push job's payload until the job engine's own clean-up (done 14 days, failed 90).
-- Admin job lists never return payloads. Replaces only public.messages_push() (as of 20261118_2300).
-- Rollback: supabase/rollback/20261126_6600_message_push_text_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261126_6600_message_push_text.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regprocedure('public.messages_push()') IS NULL THEN
    RAISE EXCEPTION 'PT-6600-PRE-001: messages_push is missing';
  END IF;
  IF pg_get_functiondef(to_regprocedure('public.messages_push()')) NOT LIKE '%messages.skip_push%' THEN
    RAISE EXCEPTION 'PT-6600-PRE-002: messages_push is not the 20261118_2300 version';
  END IF;
  IF EXISTS (SELECT 1 FROM public.system_flags WHERE key = 'message_push_text') THEN
    RAISE EXCEPTION 'PT-6600-PRE-003: already applied — roll back first';
  END IF;
END
$pre$;

INSERT INTO public.system_flags (key, value) VALUES ('message_push_text', true);

CREATE OR REPLACE FUNCTION public.messages_push()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _r      record;
  _name   text;
  _push   boolean;
  _line   text;
BEGIN
  IF NEW.status <> 'sent' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status <> 'held' THEN RETURN NEW; END IF;
  IF coalesce(current_setting('messages.skip_push', true), '') = 'on' THEN RETURN NEW; END IF;   -- a broadcast saved with push off
  IF NOT (coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false)
          AND coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine_push'), false)) THEN
    RETURN NEW;
  END IF;
  BEGIN
    IF public.has_role(NEW.sender_id, 'admin'::public.app_role) THEN
      _name := '50mm Retina World';                                       -- an admin always shows as the brand
    ELSE
      SELECT coalesce(nullif(btrim(p.full_name), ''), 'Someone') INTO _name FROM public.profiles p WHERE p.id = NEW.sender_id;
      _name := coalesce(_name, 'Someone');
    END IF;
    _line := 'sent you a message';
    IF coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'message_push_text'), false) THEN
      _line := btrim(regexp_replace(coalesce(NEW.body, ''), '\s+', ' ', 'g'));
      IF _line = '' THEN
        _line := CASE WHEN NEW.kind = 'photo' THEN 'sent a photo' ELSE 'sent you a message' END;
      ELSIF char_length(_line) > 160 THEN
        _line := left(_line, 159) || '…';
      END IF;
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
          'body', CASE WHEN _r.folder = 'requests' THEN 'sent you a message request' ELSE _line END,
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

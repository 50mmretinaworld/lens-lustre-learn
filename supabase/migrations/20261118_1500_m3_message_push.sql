-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1500 · M3 — push for a new private message, on the job engine
-- Needs M1. Owner rule: "push shows the sender's name, not the message text, on a
-- locked phone". One AFTER trigger on messages (so message_send stays untouched):
--   * new message with status 'sent'                       → push to the other member(s)
--   * a held message released by an admin (held → sent)    → push then
--   * held / rejected / the sender themself / a muted chat / a declined chat / a member
--     who switched push off (notification_preferences.push_enabled = false) → no push
-- The push is a 'push.send' job (retry 1/5/30 min, failed list + alarm), key
-- message:<message id>:<member> = never twice. Title = the sender's name; body is a fixed
-- line — the message text is NEVER put in the job or the push. Needs the job engine and
-- its push group switched on (same switches as every other push); with them off, no
-- push (a message is never delayed or lost because of push). Any fault here is a
-- warning and never blocks the send.
-- data.type = 'new_message', data.reference_id = the chat id (the app opens the chat
-- from it — wired in the client unit).
--
-- Live in-app delivery uses Realtime on `messages` (RLS decides who receives each row);
-- adding the table to the publication is done WITH its client subscription, because a CI
-- check requires the two lists to match.
--
-- Rollback: supabase/rollback/20261118_1500_m3_message_push_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1500_m3_message_push.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.messages') IS NULL THEN
    RAISE EXCEPTION 'M3-PRE-001: M1 (20261118_1100) is not applied';
  END IF;
  IF to_regprocedure('public.messages_push()') IS NOT NULL THEN
    RAISE EXCEPTION 'M3-PRE-002: messages_push already exists — not re-applying';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.send') THEN
    RAISE EXCEPTION 'M3-PRE-003: job kind push.send is missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

CREATE FUNCTION public.messages_push()
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

CREATE TRIGGER messages_push_insert AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.messages_push();
CREATE TRIGGER messages_push_release AFTER UPDATE OF status ON public.messages
  FOR EACH ROW WHEN (OLD.status = 'held' AND NEW.status = 'sent') EXECUTE FUNCTION public.messages_push();

COMMIT;

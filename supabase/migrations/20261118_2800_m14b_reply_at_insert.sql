-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2800 · M14b — the reply link is set when the message is stored, never edited afterwards
-- 20261118_2700 added message_send_reply, which set reply_to_id with a second UPDATE. A message can never be edited
-- (trigger messages_no_delete_no_unsend → MESSAGE_IMMUTABLE), so PROBE 2700 refused it — correctly. The rule stays; the
-- link now travels INTO the insert:
--   message_send_reply puts the target id in a transaction-local setting (messages.reply_to), runs the normal send door,
--   and the BEFORE INSERT trigger messages_set_reply copies it into the new row — only if that message is in the same
--   chat and visible to the sender. The door then checks the stored row really carries the link (else the whole send is
--   refused and rolled back). The setting is cleared straight after. No UPDATE of a message exists anywhere.
--
-- Rollback: supabase/rollback/20261118_2800_m14b_reply_at_insert_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2700_m14_reply_to.sql (re-run; now also checks R7 the link cannot be edited)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_send_reply(uuid,text,uuid,bigint,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'M14b-PRE-001: M14 (20261118_2700) is not applied';
  END IF;
  IF to_regprocedure('public.messages_set_reply()') IS NOT NULL THEN
    RAISE EXCEPTION 'M14b-PRE-002: messages_set_reply already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

CREATE FUNCTION public.messages_set_reply()
RETURNS trigger
LANGUAGE plpgsql SET search_path = ''
AS $fn$
DECLARE _r text := nullif(current_setting('messages.reply_to', true), ''); _id bigint;
BEGIN
  IF _r IS NULL OR _r !~ '^[0-9]{1,18}$' THEN RETURN NEW; END IF;
  _id := _r::bigint;
  IF EXISTS (SELECT 1 FROM public.messages r
              WHERE r.id = _id AND r.conversation_id = NEW.conversation_id AND (r.status = 'sent' OR r.sender_id = NEW.sender_id)) THEN
    NEW.reply_to_id := _id;
  END IF;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.messages_set_reply() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER messages_set_reply BEFORE INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.messages_set_reply();

CREATE OR REPLACE FUNCTION public.message_send_reply(_to uuid, _body text, _client_msg_id uuid, _reply_to bigint, _photos jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me uuid := (SELECT auth.uid());
  _res jsonb;
  _mid bigint;
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in to send a message' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF _reply_to IS NULL THEN RAISE EXCEPTION 'MSG-080: say which message you are replying to' USING ERRCODE = 'invalid_parameter_value'; END IF;
  PERFORM set_config('messages.reply_to', _reply_to::text, true);
  BEGIN
    _res := public.message_send_core(_to, _body, _client_msg_id, coalesce(_photos, '[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('messages.reply_to', '', true);
    RAISE;
  END;
  PERFORM set_config('messages.reply_to', '', true);
  _mid := (_res ->> 'message_id')::bigint;
  -- the stored message must carry the link: otherwise the target was not in this chat (or not visible) — refuse the whole send
  IF NOT EXISTS (SELECT 1 FROM public.messages m WHERE m.id = _mid AND m.reply_to_id = _reply_to) THEN
    RAISE EXCEPTION 'MSG-080: that message is not in this chat' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN _res;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_send_reply(uuid, text, uuid, bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_send_reply(uuid, text, uuid, bigint, jsonb) TO authenticated, service_role;

COMMIT;

-- ROLLBACK · 20261118_1100 · M1 messages tables
-- Drops every M1 object. ALL chats, members, messages, attachments rows, the control
-- list, member rules, word rules and the three logs are lost with the tables —
-- export first if any real chat exists (messages are not live to members before M2).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TABLE IF EXISTS public.message_attachments;
DROP TABLE IF EXISTS public.messages;
DROP TABLE IF EXISTS public.conversation_members;
DROP TABLE IF EXISTS public.conversations;
DROP TABLE IF EXISTS public.message_admin_reads;
DROP TABLE IF EXISTS public.message_guard_events;
DROP TABLE IF EXISTS public.message_word_rules;
DROP TABLE IF EXISTS public.message_control_log;
DROP TABLE IF EXISTS public.message_member_rules;
DROP TABLE IF EXISTS public.message_control_members;
DROP TABLE IF EXISTS public.message_control;
DROP FUNCTION IF EXISTS public.is_conversation_member(uuid);
DROP FUNCTION IF EXISTS public.messages_no_delete_no_unsend();
DROP FUNCTION IF EXISTS public.message_log_append_only();

COMMIT;

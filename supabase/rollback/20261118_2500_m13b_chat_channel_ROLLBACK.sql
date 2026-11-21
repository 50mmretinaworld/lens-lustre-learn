-- ROLLBACK · 20261118_2500 · M13b live chat channel
-- Removes the two policies and the helper. Chat channels become unusable again (the app then relies on its polls).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP POLICY IF EXISTS messages_chat_channel_read ON realtime.messages;
DROP POLICY IF EXISTS messages_chat_channel_write ON realtime.messages;
DROP FUNCTION IF EXISTS public.message_channel_member(text);

COMMIT;

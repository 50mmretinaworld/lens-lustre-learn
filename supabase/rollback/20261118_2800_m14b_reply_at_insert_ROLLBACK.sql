-- ROLLBACK · 20261118_2800 · M14b reply link at insert
-- Drops the insert trigger and its function, and the reply door (which only works with them).
-- To remove the whole reply feature also run 20261118_2700_m14_reply_to_ROLLBACK.sql.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TRIGGER IF EXISTS messages_set_reply ON public.messages;
DROP FUNCTION IF EXISTS public.messages_set_reply();
DROP FUNCTION IF EXISTS public.message_send_reply(uuid, text, uuid, bigint, jsonb);

COMMIT;

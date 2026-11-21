-- ROLLBACK · 20261118_2000 · M8b admin page reads
-- Drops the two read functions. The log's area list keeps 'lookup': the log is append-only, so rows
-- written with it cannot be removed and the narrower list could not be put back.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.admin_message_member_chats(uuid, text);
DROP FUNCTION IF EXISTS public.admin_message_word_rules();

COMMIT;

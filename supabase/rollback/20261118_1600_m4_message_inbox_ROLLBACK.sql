-- ROLLBACK · 20261118_1600 · M4 inbox / thread / read-state functions
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.message_set_muted(uuid, boolean);
DROP FUNCTION IF EXISTS public.message_decline_request(uuid);
DROP FUNCTION IF EXISTS public.message_accept_request(uuid);
DROP FUNCTION IF EXISTS public.message_mark_read(uuid);
DROP FUNCTION IF EXISTS public.message_unread_counts();
DROP FUNCTION IF EXISTS public.message_thread(uuid, bigint, integer);
DROP FUNCTION IF EXISTS public.message_my_conversations(text, integer, timestamptz);

COMMIT;

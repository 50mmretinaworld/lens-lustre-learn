-- ROLLBACK · 20261118_1200 · M2 message send door
-- Drops the four functions. Messages already sent stay in the M1 tables.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.message_send(uuid, text, uuid);
DROP FUNCTION IF EXISTS public.message_allowed_me();
DROP FUNCTION IF EXISTS public.message_word_guard(uuid, text);
DROP FUNCTION IF EXISTS public.message_control_allows(uuid);

COMMIT;

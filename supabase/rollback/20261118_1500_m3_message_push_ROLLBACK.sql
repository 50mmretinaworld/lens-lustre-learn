-- ROLLBACK · 20261118_1500 · M3 message push
-- Removes the push triggers. Jobs already queued finish normally; messages are untouched.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TRIGGER IF EXISTS messages_push_release ON public.messages;
DROP TRIGGER IF EXISTS messages_push_insert ON public.messages;
DROP FUNCTION IF EXISTS public.messages_push();

COMMIT;

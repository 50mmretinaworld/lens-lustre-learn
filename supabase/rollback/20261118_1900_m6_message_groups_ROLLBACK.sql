-- ROLLBACK · 20261118_1900 · M6 group chats
-- Drops the group functions. Existing group chats and their messages stay in the M1 tables
-- (members can still read them); nobody can create, change or post to a group any more.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.message_send_group(uuid, text, uuid);
DROP FUNCTION IF EXISTS public.message_group_leave(uuid);
DROP FUNCTION IF EXISTS public.message_group_remove(uuid, uuid);
DROP FUNCTION IF EXISTS public.message_group_add(uuid, uuid);
DROP FUNCTION IF EXISTS public.message_group_create(text, uuid[]);
DROP FUNCTION IF EXISTS public.message_group_can_take(uuid, uuid);
DROP FUNCTION IF EXISTS public.message_group_gate();

COMMIT;

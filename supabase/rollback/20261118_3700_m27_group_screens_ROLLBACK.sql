-- ROLLBACK · 20261118_3700 · M27 group screens
-- Drops the three screen reads and puts message_group_can_take back (it ignores the chat switch again).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.message_group_members(uuid);
DROP FUNCTION IF EXISTS public.message_group_friends();
DROP FUNCTION IF EXISTS public.message_groups_allowed_me();

DO $patch$
DECLARE
  _def text := pg_get_functiondef('public.message_group_can_take(uuid,uuid)'::regprocedure);
BEGIN
  EXECUTE replace(_def, 'AND public.account_can_act(_other) AND public.message_control_allows(_other)', 'AND public.account_can_act(_other)');
END
$patch$;

COMMIT;

-- ROLLBACK · 20261118_2910 · M16 recipient gate
-- Removes the recipient-switch condition from message_send_core and drops message_can_reach
-- (a member outside the admin list can be written to again; the profile icon needs the client reverted too).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DO $patch$
DECLARE
  _def text := pg_get_functiondef('public.message_send_core(uuid,text,uuid,jsonb)'::regprocedure);
  _old constant text := 'OR NOT public.account_can_act(_to) OR NOT public.message_control_allows(_to) THEN';
  _new constant text := 'OR NOT public.account_can_act(_to) THEN';
BEGIN
  IF position(_old IN _def) > 0 THEN
    EXECUTE replace(_def, _old, _new);
  END IF;
END
$patch$;

DROP FUNCTION IF EXISTS public.message_can_reach(uuid);

COMMIT;

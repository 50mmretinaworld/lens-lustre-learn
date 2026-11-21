-- ROLLBACK · 20261118_1300 · M2b messages admin switch functions
-- Drops the functions only. message_control, the list, member rules and the log stay (M1 tables).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.message_admin_state();
DROP FUNCTION IF EXISTS public.message_admin_clear_member_rule(uuid, text);
DROP FUNCTION IF EXISTS public.message_admin_set_member_rule(uuid, boolean, boolean, boolean, boolean, integer, timestamptz, text);
DROP FUNCTION IF EXISTS public.message_admin_list_remove(uuid, text);
DROP FUNCTION IF EXISTS public.message_admin_list_add(uuid, text);
DROP FUNCTION IF EXISTS public.message_admin_set_groups(boolean, text);
DROP FUNCTION IF EXISTS public.message_admin_set_mode(text, text);
DROP FUNCTION IF EXISTS public.message_admin_check(text);

COMMIT;

-- ROLLBACK · 20261118_3900 · M30 — puts the three switch functions back without the WHERE (the switches then fail again on the live site).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DO $undo$
DECLARE _sig text;
BEGIN
  FOREACH _sig IN ARRAY ARRAY[
    'public.message_admin_set_mode(text,text)',
    'public.message_admin_set_groups(boolean,text)',
    'public.admin_message_welcome_set(boolean,text,boolean)'
  ] LOOP
    EXECUTE replace(pg_get_functiondef(_sig::regprocedure), 'updated_at = now() WHERE id;', 'updated_at = now();');
  END LOOP;
END
$undo$;

COMMIT;

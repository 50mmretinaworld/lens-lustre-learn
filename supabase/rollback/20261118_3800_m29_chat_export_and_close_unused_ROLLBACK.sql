-- ROLLBACK · 20261118_3800 · M29 chat export + closing of four unused admin functions
-- Drops the export function and gives the four closed admin functions back to signed-in users (each still checks admin inside).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.admin_message_export(uuid, uuid);

DO $open$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('admin_message_member_chats', 'admin_read_conversation', 'admin_message_held_queue', 'admin_message_review') LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', r.sig);
  END LOOP;
END
$open$;

COMMIT;

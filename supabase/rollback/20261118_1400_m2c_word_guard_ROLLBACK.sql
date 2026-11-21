-- ROLLBACK · 20261118_1400 · M2c word guard
-- Puts the M2 stub back ('ok' for every text) and drops the two admin functions.
-- message_send keeps working: the extra 'help' flag it returns is simply always false.
-- The seeded word rules stay in message_word_rules (admin tables are records).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.message_admin_word_set_active(bigint, boolean, text);
DROP FUNCTION IF EXISTS public.message_admin_word_add(text, text, text, text, text);
DROP FUNCTION public.message_word_guard(uuid, text);
CREATE FUNCTION public.message_word_guard(_uid uuid, _body text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT 'ok'::text; $fn$;
REVOKE ALL ON FUNCTION public.message_word_guard(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_word_guard(uuid, text) TO service_role;

COMMIT;

-- ROLLBACK · 20261118_4000 · M31 default rule
-- Puts every patched messaging check back exactly as it was (definitions saved in message_m31_backup), then drops the
-- default-rule functions and tables. Members' own rules are not touched (an "apply to everyone" already done stays done).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_m31_backup') IS NULL THEN
    RAISE EXCEPTION 'M31-RB-001: message_m31_backup missing — M31 is not applied';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DO $undo$
DECLARE rec record;
BEGIN
  FOR rec IN SELECT fn, def FROM public.message_m31_backup LOOP
    EXECUTE rec.def;
  END LOOP;
END
$undo$;

DROP FUNCTION IF EXISTS public.message_admin_set_default(boolean, boolean, boolean, boolean, integer, integer, boolean, text);
DROP FUNCTION IF EXISTS public.admin_message_default_get();
DROP FUNCTION IF EXISTS public.message_effective_rule(uuid);
DROP TABLE IF EXISTS public.message_default_rules;
DROP TABLE IF EXISTS public.message_m31_backup;

COMMIT;

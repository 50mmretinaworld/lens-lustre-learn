-- ═══════════════════════════════════════════════════════════════════════════
-- 20261126_6900 · Off-switch for the sender's photo on message notifications. Lanes: staging, production.
-- The photo needs new app code that has never run on members' phones, so it can be turned off without a build:
-- send-push reads system_flags.message_push_photo (false → every phone gets the ordinary notification).
--   ON  = run this file (safe to run again)
--   OFF = run supabase/rollback/20261126_6900_message_push_photo_switch_ROLLBACK.sql
-- PROBE: supabase/migrations/PROBE_20261126_6900_message_push_photo_switch.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

INSERT INTO public.system_flags (key, value) VALUES ('message_push_photo', true)
ON CONFLICT (key) DO UPDATE SET value = true;

COMMIT;

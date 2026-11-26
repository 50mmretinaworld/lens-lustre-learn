-- Switch the sender's photo OFF (20261126_6900): every phone gets the ordinary message notification again.
-- Run 20261126_6900 to switch it back on.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

INSERT INTO public.system_flags (key, value) VALUES ('message_push_photo', false)
ON CONFLICT (key) DO UPDATE SET value = false;

COMMIT;

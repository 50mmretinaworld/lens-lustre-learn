-- PROBE · 20261126_6900 photo switch. READ ONLY. Prints whether the photo is ON; fails if the switch is missing.
BEGIN READ ONLY;

DO $p$
DECLARE _on boolean;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  SELECT value INTO _on FROM public.system_flags WHERE key = 'message_push_photo';
  IF _on IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL: switch message_push_photo missing (6900 not applied)';
  END IF;
  RAISE NOTICE 'PROBE PASS: message notification photo is %', CASE WHEN _on THEN 'ON' ELSE 'OFF' END;
END
$p$;

ROLLBACK;

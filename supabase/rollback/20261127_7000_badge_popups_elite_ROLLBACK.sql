-- Rollback of 20261127_7000. Removes the popup texts, the trigger and the Elite Member badge (and who holds it).
BEGIN;
DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TRIGGER IF EXISTS trg_latest_tick_wins ON public.user_badges;
DROP FUNCTION IF EXISTS public.latest_tick_wins();
DELETE FROM public.user_badges WHERE badge_type = 'elite_member';
DELETE FROM public.badge_definitions WHERE type_key = 'elite_member';
ALTER TABLE public.badge_definitions DROP CONSTRAINT IF EXISTS badge_definitions_popup_len,
  DROP COLUMN IF EXISTS show_label, DROP COLUMN IF EXISTS popup_title, DROP COLUMN IF EXISTS popup_message;
ALTER TABLE public.role_display_config DROP CONSTRAINT IF EXISTS role_display_config_popup_len,
  DROP COLUMN IF EXISTS show_label, DROP COLUMN IF EXISTS popup_title, DROP COLUMN IF EXISTS popup_message;
COMMIT;

-- ROLLBACK · 20261126_6100 premium honour notification. Puts notify_badge_awarded() back to the body it had before
-- 6100 (20260325141209_0d9f5acf…): every badge, 'verified' included, says 'New Badge!' again.
-- Same SECURITY DEFINER and search_path; CREATE OR REPLACE keeps owner and grants. Notifications already sent stay.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

CREATE OR REPLACE FUNCTION public.notify_badge_awarded()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _badge_label text;
BEGIN
  SELECT label INTO _badge_label FROM public.badge_definitions WHERE type_key = NEW.badge_type LIMIT 1;
  INSERT INTO public.user_notifications (user_id, actor_id, type, title, message, reference_id)
  VALUES (NEW.user_id, NEW.assigned_by, 'badge_awarded', 'New Badge!', 'You''ve been awarded the "' || COALESCE(_badge_label, NEW.badge_type) || '" badge! 🏅', NEW.id);
  RETURN NEW;
END;
$$;

COMMIT;

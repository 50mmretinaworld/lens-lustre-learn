-- ROLLBACK · 20261128_7100 honour "Share my honour" e-mail. Puts notify_badge_awarded() back to the 20261126_6100
-- body: 'verified' says "You've been honoured" (bell + push only, no e-mail); every other badge, 'elite_member'
-- included, says 'New Badge!'. E-mails already queued or sent stay. Same DEFINER / search_path; CREATE OR REPLACE
-- keeps owner and grants.
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
  IF NEW.badge_type = 'verified' THEN
    INSERT INTO public.user_notifications (user_id, actor_id, type, title, message, reference_id)
    VALUES (NEW.user_id, NEW.assigned_by, 'badge_awarded', 'You''ve been honoured',
            'The 50mm Retina World curators have honoured you as a Premium Member. Choose your Featured photo to show on your card.',
            NEW.id);
    RETURN NEW;
  END IF;
  SELECT label INTO _badge_label FROM public.badge_definitions WHERE type_key = NEW.badge_type LIMIT 1;
  INSERT INTO public.user_notifications (user_id, actor_id, type, title, message, reference_id)
  VALUES (NEW.user_id, NEW.assigned_by, 'badge_awarded', 'New Badge!', 'You''ve been awarded the "' || COALESCE(_badge_label, NEW.badge_type) || '" badge! 🏅', NEW.id);
  RETURN NEW;
END;
$$;

COMMIT;

-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 20261126_6100 · PREMIUM MEMBERS — the honour notification (Owner-approved plan, 26 Nov 2026, Part 1 step 3).
-- Lanes: staging, production.
--
-- Changes ONLY what notify_badge_awarded() says when the badge is 'verified':
--   title   "You've been honoured"
--   message "The 50mm Retina World curators have honoured you as a Premium Member. Choose your Featured photo to
--            show on your card."
-- Every other badge keeps today's words ('New Badge!' / 'You've been awarded the "<label>" badge! 🏅').
--
-- Body taken from the newest migration that defines the function (20260325141209_0d9f5acf…, the same body the
-- 20260911 schema dump records). Same SECURITY DEFINER, same search_path ('public'), same trigger, same row written
-- (user_id, actor_id, type 'badge_awarded', title, message, reference_id). CREATE OR REPLACE keeps the function's
-- owner and grants as they are, and its name stays on notification_writer_allowlist (20261104_0130) unchanged.
--
-- Rollback: supabase/rollback/20261126_6100_premium_honour_notification_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261126_6100_premium_honour_notification.sql
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
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

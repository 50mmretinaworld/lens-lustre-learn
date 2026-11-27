-- ═══════════════════════════════════════════════════════════════════════════
-- 20261127_7000 · Badge / role popups written by Admin, and the gold "Elite Member" tick. Lanes: staging, production.
-- Owner 27 Nov 2026 (sample approved):
--   • per badge and role: show the name next to the icon (on/off), popup heading, popup message
--   • new badge "Elite Member" (gold tick), given by Admin only (user_badges RLS is unchanged)
--   • blue and gold together: the latest wins. Gold is drawn over blue; giving blue AFTER gold removes the gold.
--     The blue row is never removed (it is what lists a member on Premium Members).
-- Not re-runnable as an apply (PRE-001). Rollback: supabase/rollback/20261127_7000_badge_popups_elite_ROLLBACK.sql
-- PROBE: supabase/migrations/PROBE_20261127_7000_badge_popups_elite.sql
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

DO $pre$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'badge_definitions' AND column_name = 'popup_message') THEN
    RAISE EXCEPTION 'B7000-PRE-001: already applied — roll back first';
  END IF;
  IF to_regclass('public.user_badges') IS NULL OR to_regclass('public.role_display_config') IS NULL THEN
    RAISE EXCEPTION 'B7000-PRE-002: badge tables are missing';
  END IF;
END
$pre$;

ALTER TABLE public.badge_definitions
  ADD COLUMN show_label boolean NOT NULL DEFAULT true,
  ADD COLUMN popup_title text,
  ADD COLUMN popup_message text,
  ADD CONSTRAINT badge_definitions_popup_len CHECK (char_length(popup_title) <= 80 AND char_length(popup_message) <= 400);

ALTER TABLE public.role_display_config
  ADD COLUMN show_label boolean NOT NULL DEFAULT true,
  ADD COLUMN popup_title text,
  ADD COLUMN popup_message text,
  ADD CONSTRAINT role_display_config_popup_len CHECK (char_length(popup_title) <= 80 AND char_length(popup_message) <= 400);

INSERT INTO public.badge_definitions (type_key, label, icon, badge_class, ribbon_class, sort_order)
VALUES ('elite_member', 'Elite Member', '✓', 'bg-amber-700',
        'bg-gradient-to-r from-amber-700 to-yellow-500 text-white shadow-amber-500/30',
        (SELECT coalesce(max(sort_order), 0) + 1 FROM public.badge_definitions))
ON CONFLICT (type_key) DO NOTHING;

CREATE FUNCTION public.latest_tick_wins()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  DELETE FROM public.user_badges WHERE user_id = NEW.user_id AND badge_type = 'elite_member';
  RETURN NULL;
END
$fn$;
REVOKE ALL ON FUNCTION public.latest_tick_wins() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_latest_tick_wins
AFTER INSERT ON public.user_badges
FOR EACH ROW WHEN (NEW.badge_type = 'verified')
EXECUTE FUNCTION public.latest_tick_wins();

COMMIT;

-- ROLLBACK · 20261126_6000 premium members. Removes everything 6000 added, in reverse order.
-- ⚠ Drops the admins' curator lines (user_badges.citation) and every member's Featured photo choice.
--   The Verified badges themselves (user_badges rows) are NOT touched.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

DROP FUNCTION IF EXISTS public.get_premium_members(integer);
DROP TRIGGER IF EXISTS trg_clear_featured_on_unverify ON public.user_badges;
DROP FUNCTION IF EXISTS public.clear_featured_on_unverify();
DROP FUNCTION IF EXISTS public.set_featured_post(uuid);
DROP TABLE IF EXISTS public.premium_featured_posts;
ALTER TABLE public.user_badges DROP CONSTRAINT IF EXISTS user_badges_citation_len;
ALTER TABLE public.user_badges DROP COLUMN IF EXISTS citation;

COMMIT;

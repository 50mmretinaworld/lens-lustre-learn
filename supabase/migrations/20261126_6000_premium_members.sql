-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 20261126_6000 · PREMIUM MEMBERS (Owner 26 Nov 2026: "Rest all approved … only this work 1st").
-- Lanes: staging, production.
--
-- The Verified tick is an honour an admin gives (user_badges badge_type 'verified', admin-only writes, unchanged).
-- This adds what the approved design needs on top of it:
--
--   1. user_badges.citation   — the admin's ONE public line on why the member was honoured (≤ 140 letters).
--                               Admins already manage user_badges (policy "Admins can manage badges"); no new policy.
--   2. featured_photos        — ONE Featured photo per Premium Member, chosen by the member. A new choice replaces the
--                               old one (primary key = member). Readable by everyone (it only names a post id);
--                               nobody writes it directly — only through set_featured_post() below.
--   3. set_featured_post(id)  — the member marks one of their OWN PUBLIC photo posts as Featured (NULL = unmark).
--                               Only a member who holds the Verified badge, only a live account.
--   4. clear_featured_on_unverify — when an admin removes the Verified badge, the Featured mark goes with it.
--   5. get_premium_members()  — the public list for the feed row and the Premium Members page: name, handle, avatar,
--                               the photo (Featured, else the member's most-liked public photo), the line (admin's
--                               citation, else the first line of the member's public bio, else none), honour date and
--                               follower count. Leaves out the 50mm official account (admin role) and banned or
--                               suspended members (the same rule as the sitemap, supabase/functions/_shared/moderated.ts).
--
-- ⚠ get_premium_members is SECURITY DEFINER on purpose (signed-out visitors and Google read the page). It returns
--   only what is already public elsewhere: profiles_public_data fields (name, avatar, bio, handle), a PUBLIC member
--   post's image, badge date, and the follower count (follows: "Anyone can view follows"). Its WHERE keeps it to
--   verified, not-moderated, not-admin members and public posts. search_path '' with schema-qualified names.
--
-- Rollback: supabase/rollback/20261126_6000_premium_members_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261126_6000_premium_members.sql
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

-- 1 · the curator's line ─────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.user_badges ADD COLUMN citation text;
ALTER TABLE public.user_badges
  ADD CONSTRAINT user_badges_citation_len CHECK (citation IS NULL OR char_length(citation) <= 140);
COMMENT ON COLUMN public.user_badges.citation IS
  'Premium Members (20261126_6000): the admin''s one public line on why the member was honoured (verified badge only).';

-- 2 · one Featured photo per member ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.featured_photos (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_id uuid NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  set_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.featured_photos IS
  'Premium Members (20261126_6000): the one photo post a Verified member chose as Featured. Written only by set_featured_post().';
-- No index on post_id on purpose: at most one row per Premium Member (tens of rows), so the cascade check on a post
-- delete reads the whole table in microseconds; an index would cost more than it saves (P28).

ALTER TABLE public.featured_photos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view featured photos" ON public.featured_photos FOR SELECT USING (true);
REVOKE ALL ON public.featured_photos FROM anon, authenticated;
GRANT SELECT ON public.featured_photos TO anon, authenticated;

-- 3 · the member marks / unmarks ──────────────────────────────────────────────────────────────────────────────────
CREATE FUNCTION public.set_featured_post(_post_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := auth.uid();
BEGIN
  IF _uid IS NULL OR NOT public.account_is_live() THEN
    RAISE EXCEPTION 'Sign in to choose a Featured photo.' USING ERRCODE = '42501';
  END IF;

  IF _post_id IS NULL THEN
    DELETE FROM public.featured_photos WHERE user_id = _uid;
    RETURN NULL;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.user_badges b WHERE b.user_id = _uid AND b.badge_type = 'verified') THEN
    RAISE EXCEPTION 'Only Premium Members can choose a Featured photo.' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.posts p
     WHERE p.id = _post_id
       AND p.user_id = _uid
       AND p.privacy = 'public'
       AND p.post_kind = 'member'
       AND coalesce(nullif(p.image_url, ''), p.image_urls[1]) IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Choose one of your own public photos.' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.featured_photos (user_id, post_id, set_at)
  VALUES (_uid, _post_id, now())
  ON CONFLICT (user_id) DO UPDATE SET post_id = EXCLUDED.post_id, set_at = EXCLUDED.set_at;

  RETURN _post_id;
END
$fn$;
REVOKE ALL ON FUNCTION public.set_featured_post(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_featured_post(uuid) TO authenticated;

-- 4 · honour removed → Featured mark removed ──────────────────────────────────────────────────────────────────────
CREATE FUNCTION public.clear_featured_on_unverify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  IF OLD.badge_type = 'verified' THEN
    DELETE FROM public.featured_photos WHERE user_id = OLD.user_id;
  END IF;
  RETURN OLD;
END
$fn$;
REVOKE ALL ON FUNCTION public.clear_featured_on_unverify() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_clear_featured_on_unverify
  AFTER DELETE ON public.user_badges
  FOR EACH ROW EXECUTE FUNCTION public.clear_featured_on_unverify();

-- 5 · the public list ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE FUNCTION public.get_premium_members(_limit integer DEFAULT 60)
RETURNS TABLE (
  user_id          uuid,
  full_name        text,
  handle           text,
  avatar_url       text,
  post_id          uuid,
  photo_url        text,
  thumb_url        text,
  is_featured      boolean,
  line             text,
  line_is_citation boolean,
  honoured_at      timestamptz,
  follower_count   bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT b.user_id,
         pr.full_name,
         pr.custom_url,
         pr.avatar_url,
         ph.id,
         ph.photo_url,
         ph.thumb_url,
         coalesce(ph.is_featured, false),
         CASE
           WHEN nullif(btrim(b.citation), '') IS NOT NULL THEN btrim(b.citation)
           ELSE nullif(left(btrim(split_part(coalesce(pr.bio, ''), E'\n', 1)), 140), '')
         END,
         nullif(btrim(b.citation), '') IS NOT NULL,
         b.assigned_at,
         (SELECT count(*) FROM public.follows f WHERE f.following_id = b.user_id)
    FROM public.user_badges b
    JOIN public.profiles pr ON pr.id = b.user_id
    LEFT JOIN LATERAL (
      SELECT x.id, x.photo_url, x.thumb_url, x.is_featured
        FROM (
          SELECT p.id,
                 coalesce(nullif(p.image_url, ''), p.image_urls[1]) AS photo_url,
                 coalesce(nullif(p.thumbnail_url, ''), p.thumbnail_urls[1]) AS thumb_url,
                 (fp.post_id IS NOT NULL) AS is_featured,
                 p.likes_count,
                 p.created_at
            FROM public.posts p
            LEFT JOIN public.featured_photos fp ON fp.user_id = b.user_id AND fp.post_id = p.id
           WHERE p.user_id = b.user_id
             AND p.privacy = 'public'
             AND p.post_kind = 'member'
             AND coalesce(nullif(p.image_url, ''), p.image_urls[1]) IS NOT NULL
        ) x
       ORDER BY x.is_featured DESC, x.likes_count DESC, x.created_at DESC
       LIMIT 1
    ) ph ON true
   WHERE b.badge_type = 'verified'
     AND NOT coalesce(pr.is_banned, false)
     AND NOT coalesce(pr.is_suspended, false)
     AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = b.user_id AND r.role = 'admin')
   ORDER BY b.assigned_at DESC, b.user_id
   LIMIT least(greatest(coalesce(_limit, 60), 1), 200);
$fn$;
REVOKE ALL ON FUNCTION public.get_premium_members(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_premium_members(integer) TO anon, authenticated;

COMMIT;

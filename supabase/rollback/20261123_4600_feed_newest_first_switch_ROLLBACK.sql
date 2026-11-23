-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261123_4600 feed order switch. Lanes: staging, production.
-- Puts back exactly the state before 4600: get_feed_page = the 20261029_0500
-- body (byte for byte, generated from that file), feed_newest_timeline gone,
-- the feed_newest_first switch and its member list gone (audited), the key
-- removed from feature_access_feature_check. Every member gets the Fair mix.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED — p32.lane reads %. Dispatch apply-migration.yml (it sets p32.lane from target).',
      coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regprocedure('public.feed_newest_timeline(uuid[],integer,text[])') IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.feature_access WHERE feature = 'feed_newest_first') THEN
    RAISE EXCEPTION 'FNF-4600-RB-PRE-001: 4600 is not applied — nothing to roll back';
  END IF;
END
$pre$;

-- 1. get_feed_page back to the 20261029_0500 body (before the function it calls is dropped)
CREATE OR REPLACE FUNCTION public.get_feed_page(
  _tab text, _personal boolean, _session_seed text, _after integer,
  _limit integer, _newest_first integer, _categories text[])
 RETURNS TABLE(id uuid, user_id uuid, content text, image_url text, image_urls text[], privacy text,
               created_at timestamp with time zone, likes_count integer, comments_count integer,
               shares_count integer, feed_tier text, author_name text, author_avatar text,
               thumbnail_urls text[], categories text[], source text, caught_up_after boolean,
               feed_pos integer)
 LANGUAGE plpgsql
 VOLATILE
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
#variable_conflict use_column
DECLARE
  _me   uuid    := (SELECT auth.uid());
  _seed text    := left(btrim(coalesce(_session_seed, '')), 64);
  _from integer := GREATEST(coalesce(_after, 0), 0);
  _key  text;
  _ex   uuid[];
BEGIN
  IF _me IS NULL THEN
    RETURN;
  END IF;
  IF _tab IS NULL OR _tab NOT IN ('for_you', 'following', 'favourites') THEN
    RAISE EXCEPTION 'get_feed_page: _tab must be for_you, following or favourites' USING ERRCODE = '22023';
  END IF;
  IF _seed = '' OR length(btrim(_session_seed)) > 64 THEN
    RAISE EXCEPTION 'get_feed_page: _session_seed is required (1-64 characters)' USING ERRCODE = '22023';
  END IF;
  _key := md5(_tab || '|' || coalesce(array_to_string(_categories, ',', '~'), '*') || '|' || _seed);
  -- One page of one session at a time (a refetch overlapping a load-more).
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('feed_page:' || _me::text || ':' || _key, 0));

  -- Retention: a new session drops this viewer's log rows older than a day.
  IF _from = 0 THEN
    DELETE FROM public.feed_session_delivered d
     WHERE d.viewer = _me AND d.delivered_at < now() - interval '1 day';
  END IF;
  -- A retry / refetch of a page re-deals it: forget what was dealt after _after.
  DELETE FROM public.feed_session_delivered d
   WHERE d.viewer = _me AND d.session_key = _key AND d.pos > _from;
  -- Exactly the list the client used to upload, in delivery order.
  SELECT coalesce(array_agg(d.post_id ORDER BY d.pos), '{}'::uuid[]) INTO _ex
    FROM public.feed_session_delivered d
   WHERE d.viewer = _me AND d.session_key = _key;
  -- The client holds rows this log never dealt (a page served by the old
  -- _exclude_ids call, or a log already purged): refuse rather than deal from
  -- an incomplete list — the client then pages the old way, with its full list.
  IF _from > coalesce(cardinality(_ex), 0) THEN
    RAISE EXCEPTION 'get_feed_page: cursor % is ahead of this session''s log (%)', _from, coalesce(cardinality(_ex), 0)
      USING ERRCODE = '22023';
  END IF;

  IF _tab = 'for_you' AND coalesce(_personal, false) THEN
    RETURN QUERY
    WITH pg AS MATERIALIZED (
      SELECT f.id, f.user_id, f.content, f.image_url, f.image_urls, f.privacy, f.created_at,
             f.likes_count, f.comments_count, f.shares_count, f.feed_tier, f.author_name, f.author_avatar,
             f.thumbnail_urls, f.categories, f.source, f.caught_up_after, (_from + f.o)::integer AS pos
        FROM public.get_personal_feed(_ex, _limit, _newest_first, _categories, _session_seed)
             WITH ORDINALITY AS f(id, user_id, content, image_url, image_urls, privacy, created_at, likes_count,
                                  comments_count, shares_count, feed_tier, author_name, author_avatar,
                                  thumbnail_urls, categories, source, caught_up_after, o)
    ), ins AS (
      INSERT INTO public.feed_session_delivered AS t (viewer, session_key, pos, post_id)
      SELECT _me, _key, pg.pos, pg.id FROM pg
      ON CONFLICT (viewer, session_key, pos) DO UPDATE SET post_id = EXCLUDED.post_id, delivered_at = now()
    )
    SELECT pg.id, pg.user_id, pg.content, pg.image_url, pg.image_urls, pg.privacy, pg.created_at,
           pg.likes_count, pg.comments_count, pg.shares_count, pg.feed_tier, pg.author_name, pg.author_avatar,
           pg.thumbnail_urls, pg.categories, pg.source, pg.caught_up_after, pg.pos
      FROM pg ORDER BY pg.pos;
  ELSIF _tab = 'for_you' THEN
    RETURN QUERY
    WITH pg AS MATERIALIZED (
      SELECT b.id, b.user_id, b.content, b.image_url, b.image_urls, b.privacy, b.created_at,
             b.likes_count, b.comments_count, b.shares_count, b.feed_tier, b.author_name, b.author_avatar,
             b.thumbnail_urls, b.categories, (_from + b.o)::integer AS pos
        FROM public.get_broadcast_feed(_ex, _limit, _newest_first, _categories, _session_seed)
             WITH ORDINALITY AS b(id, user_id, content, image_url, image_urls, privacy, created_at, likes_count,
                                  comments_count, shares_count, feed_tier, author_name, author_avatar,
                                  thumbnail_urls, categories, o)
    ), ins AS (
      INSERT INTO public.feed_session_delivered AS t (viewer, session_key, pos, post_id)
      SELECT _me, _key, pg.pos, pg.id FROM pg
      ON CONFLICT (viewer, session_key, pos) DO UPDATE SET post_id = EXCLUDED.post_id, delivered_at = now()
    )
    SELECT pg.id, pg.user_id, pg.content, pg.image_url, pg.image_urls, pg.privacy, pg.created_at,
           pg.likes_count, pg.comments_count, pg.shares_count, pg.feed_tier, pg.author_name, pg.author_avatar,
           pg.thumbnail_urls, pg.categories, NULL::text, false, pg.pos
      FROM pg ORDER BY pg.pos;
  ELSE
    -- Following / Favourites: exactly what get_following_feed / get_favourites_feed return.
    RETURN QUERY
    WITH pg AS MATERIALIZED (
      SELECT f.id, f.user_id, f.content, f.image_url, f.image_urls, f.privacy, f.created_at,
             f.likes_count, f.comments_count, f.shares_count, f.feed_tier, f.author_name, f.author_avatar,
             f.thumbnail_urls, f.categories, f.source, f.caught_up_after, (_from + f.o)::integer AS pos
        FROM public.feed_author_timeline(_tab, _ex, _limit, _categories)
             WITH ORDINALITY AS f(id, user_id, content, image_url, image_urls, privacy, created_at, likes_count,
                                  comments_count, shares_count, feed_tier, author_name, author_avatar,
                                  thumbnail_urls, categories, source, caught_up_after, o)
    ), ins AS (
      INSERT INTO public.feed_session_delivered AS t (viewer, session_key, pos, post_id)
      SELECT _me, _key, pg.pos, pg.id FROM pg
      ON CONFLICT (viewer, session_key, pos) DO UPDATE SET post_id = EXCLUDED.post_id, delivered_at = now()
    )
    SELECT pg.id, pg.user_id, pg.content, pg.image_url, pg.image_urls, pg.privacy, pg.created_at,
           pg.likes_count, pg.comments_count, pg.shares_count, pg.feed_tier, pg.author_name, pg.author_avatar,
           pg.thumbnail_urls, pg.categories, pg.source, pg.caught_up_after, pg.pos
      FROM pg ORDER BY pg.pos;
  END IF;
END
$fn$;

COMMENT ON FUNCTION public.get_feed_page(text, boolean, text, integer, integer, integer, text[]) IS
  'S6-a (20261029_0500): one feed page by cursor (_after = delivery position of the last row the client holds) instead of _exclude_ids. Evaluates the unchanged get_personal_feed / get_broadcast_feed (session overload) / feed_author_timeline with the session''s server-side delivery log, so the order is today''s. Viewer = auth.uid(). authenticated only.';

REVOKE ALL ON FUNCTION public.get_feed_page(text, boolean, text, integer, integer, integer, text[]) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_feed_page(text, boolean, text, integer, integer, integer, text[]) TO authenticated;

-- 2. the newest-first list
DROP FUNCTION IF EXISTS public.feed_newest_timeline(uuid[], integer, text[]);

-- 3. the switch (its member list goes with it: FK cascade is not assumed)
LOCK TABLE public.feature_access IN ACCESS EXCLUSIVE MODE;
DELETE FROM public.feature_access_members WHERE feature = 'feed_newest_first';
WITH del AS (
  DELETE FROM public.feature_access WHERE feature = 'feed_newest_first' RETURNING feature, mode
)
INSERT INTO public.feature_access_audit (actor, feature, action, old_value, new_value, note)
SELECT NULL, del.feature, 'mode', del.mode, NULL, '20261123_4600 ROLLBACK: switch removed (feed order = Fair mix)'
  FROM del;

DO $switch$
DECLARE _def text; _keys text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO _def FROM pg_constraint c
   WHERE c.conrelid = 'public.feature_access'::regclass AND c.conname = 'feature_access_feature_check';
  IF _def IS NULL OR _def !~ '^CHECK \(\(feature = ANY \(ARRAY\[''[a-z0-9_]+''::text(, ''[a-z0-9_]+''::text)*\]\)\)\)$' THEN
    RAISE EXCEPTION 'FNF-4600-RB-PRE-002: feature_access_feature_check is not a plain key list (read: %)', coalesce(_def, '<none>');
  END IF;
  SELECT array_agg(t.m[1] ORDER BY t.i) INTO _keys
    FROM regexp_matches(_def, '''([a-z0-9_]+)''::text', 'g') WITH ORDINALITY AS t(m, i)
   WHERE t.m[1] <> 'feed_newest_first';
  EXECUTE format(
    'ALTER TABLE public.feature_access DROP CONSTRAINT feature_access_feature_check, '
    'ADD CONSTRAINT feature_access_feature_check CHECK (feature IN (%s))',
    (SELECT string_agg(quote_literal(k), ', ' ORDER BY i) FROM unnest(_keys) WITH ORDINALITY AS u(k, i)));
END
$switch$;

DO $post$
DECLARE _md5 text;
BEGIN
  SELECT md5(p.prosrc) INTO _md5 FROM pg_proc p
   WHERE p.oid = 'public.get_feed_page(text,boolean,text,integer,integer,integer,text[])'::regprocedure;
  IF _md5 IS DISTINCT FROM '4f28c86b1ab3e6e31916c60d407a3ee9'
     OR to_regprocedure('public.feed_newest_timeline(uuid[],integer,text[])') IS NOT NULL
     OR EXISTS (SELECT 1 FROM public.feature_access WHERE feature = 'feed_newest_first') THEN
    RAISE EXCEPTION 'FNF-4600-RB-POST: not back to the pre-4600 state (get_feed_page md5 %)', _md5;
  END IF;
  RAISE NOTICE 'FNF-4600 ROLLBACK: get_feed_page back to the 20261029_0500 body; feed_newest_timeline dropped; switch removed';
END
$post$;

COMMIT;

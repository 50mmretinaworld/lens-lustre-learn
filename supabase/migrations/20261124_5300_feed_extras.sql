-- ═══════════════════════════════════════════════════════════════════════════
-- 20261124_5300 · N6-2: ONE request for a feed page's extras instead of ~12 (Owner 24 Nov: "go on").
-- Lanes: staging, production.
--
-- Measured (UI harness, real app code, 24 Nov): after get_feed_page every feed page sent ~12 more reads in 3–4
-- waves — names (profiles_public_data, then user_badges + roles), reactions, friendships, view counts, tags, then
-- the tagged people's names (a second wave), photos (post_media_for), videos (post_videos), contributor scores and
-- old-photo credits. Each is ~0.2 s of travel from India. get_feed_extras() answers all of them in ONE round trip,
-- including the tagged people's names (no second wave).
--
-- ⚠ SECURITY INVOKER ON PURPOSE. It runs with the CALLER's rights, exactly like the separate requests it replaces:
-- every table read below goes through the same row-level security the app's direct reads go through, and every
-- function it calls is the same one the app already calls (the definer ones keep their own checks, e.g.
-- post_media_for's can_view_post). It can never return anything the member could not already read with those
-- requests. Each part is in its own exception block: a part that fails is LEFT OUT, and the app asks for that part
-- the old way.
--
-- Not re-runnable as an apply (PRE-002). Rollback: supabase/rollback/20261124_5300_feed_extras_ROLLBACK.sql
-- PROBE: supabase/migrations/PROBE_20261124_5300_feed_extras.sql (every part equals the separate request, real members).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regprocedure('public.get_feed_extras(uuid[],uuid[],boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'N6-5300-PRE-002: already applied — roll back first';
  END IF;
  IF to_regclass('public.profiles_public_data') IS NULL OR to_regclass('public.user_badges') IS NULL
     OR to_regclass('public.post_reactions') IS NULL OR to_regclass('public.friendships') IS NULL
     OR to_regclass('public.post_tags') IS NULL
     OR to_regprocedure('public.get_public_roles_for_users(uuid[])') IS NULL
     OR to_regprocedure('public.get_post_view_counts(uuid[])') IS NULL
     OR to_regprocedure('public.post_media_for(uuid[])') IS NULL
     OR to_regprocedure('public.get_contributor_scores(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'N6-5300-PRE-001: a table or function the feed extras read is missing';
  END IF;
  -- post_videos / videos / video_versions and post_photo_credit_for may be absent on a lane: those parts are then
  -- simply left out at run time (their exception blocks), and the app asks for them alone, as today.
END
$pre$;

CREATE FUNCTION public.get_feed_extras(_post_ids uuid[], _author_ids uuid[], _credits boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $fn$
DECLARE
  _uid    uuid := (SELECT auth.uid());
  _out    jsonb := '{}'::jsonb;
  _v      jsonb;
  _posts  uuid[];
  _people uuid[];
BEGIN
  -- Signed out, nothing asked, or more than one batch (50, the cap every separate read already has): nothing to
  -- answer; the app keeps its separate reads.
  IF _uid IS NULL OR _post_ids IS NULL OR cardinality(_post_ids) = 0 OR cardinality(_post_ids) > 50
     OR cardinality(coalesce(_author_ids, '{}')) > 50 THEN
    RETURN _out;
  END IF;
  SELECT array_agg(DISTINCT x) INTO _posts FROM unnest(_post_ids) x WHERE x IS NOT NULL;
  _people := coalesce((SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(_author_ids) x WHERE x IS NOT NULL), '{}');

  -- The ⚑ comment on each part names the app reader it replaces (and therefore the request it must equal).
  BEGIN                                                                     -- ⚑ enrichPosts: post_tags
    SELECT coalesce(jsonb_agg(jsonb_build_object('post_id', t.post_id, 'tagged_user_id', t.tagged_user_id,
                                                 'status', t.status)
                              ORDER BY t.post_id, t.tagged_user_id, t.id), '[]'::jsonb) INTO _v
      FROM public.post_tags t WHERE t.post_id = ANY(_posts) AND t.status IN ('pending', 'approved');
    _out := _out || jsonb_build_object('tags', _v);
    -- the tagged people's names ride in the same answer (today: a second wave of three requests)
    _people := coalesce((SELECT array_agg(DISTINCT u ORDER BY u) FROM (
                 SELECT unnest(_people) AS u
                 UNION SELECT (e ->> 'tagged_user_id')::uuid FROM jsonb_array_elements(_v) e) s), '{}');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  IF cardinality(_people) BETWEEN 1 AND 100 THEN
    BEGIN                                                                   -- ⚑ profileMapCache (signed-in read)
      SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'avatar_url', p.avatar_url,
                                                   'custom_url', p.custom_url, 'last_active_at', p.last_active_at)
                                ORDER BY p.id), '[]'::jsonb) INTO _v
        FROM public.profiles_public_data p WHERE p.id = ANY(_people);
      _out := _out || jsonb_build_object('profile_ids', to_jsonb(_people), 'profiles', _v);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN                                                                   -- ⚑ profileMapCache: user_badges
      SELECT coalesce(jsonb_agg(jsonb_build_object('user_id', b.user_id, 'badge_type', b.badge_type)
                                ORDER BY b.user_id, b.badge_type), '[]'::jsonb) INTO _v
        FROM public.user_badges b WHERE b.user_id = ANY(_people);
      _out := _out || jsonb_build_object('badges', _v);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN                                                                   -- ⚑ profileMapCache: roles
      SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.user_id, r.role), '[]'::jsonb) INTO _v
        FROM public.get_public_roles_for_users(_people) r;
      _out := _out || jsonb_build_object('roles', _v);
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  BEGIN                                                                     -- ⚑ enrichPosts: post_reactions
    SELECT coalesce(jsonb_agg(jsonb_build_object('post_id', r.post_id, 'reaction_type', r.reaction_type,
                                                 'user_id', r.user_id)
                              ORDER BY r.post_id, r.user_id, r.reaction_type), '[]'::jsonb) INTO _v
      FROM public.post_reactions r WHERE r.post_id = ANY(_posts);
    _out := _out || jsonb_build_object('reactions', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                     -- ⚑ enrichPosts: friendships
    SELECT coalesce(jsonb_agg(jsonb_build_object('requester_id', f.requester_id, 'addressee_id', f.addressee_id,
                                                 'status', f.status)
                              ORDER BY f.requester_id, f.addressee_id), '[]'::jsonb) INTO _v
      FROM public.friendships f WHERE f.requester_id = _uid OR f.addressee_id = _uid;
    _out := _out || jsonb_build_object('friendships', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                     -- ⚑ enrichPosts: get_post_view_counts
    SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.post_id), '[]'::jsonb) INTO _v
      FROM public.get_post_view_counts(_posts) c;
    _out := _out || jsonb_build_object('view_counts', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                     -- ⚑ postMediaRead: post_media_for
    SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.post_id, m.ord), '[]'::jsonb) INTO _v
      FROM public.post_media_for(_posts) m;
    _out := _out || jsonb_build_object('media', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                     -- ⚑ postVideoRead: post_videos + embed
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'post_id', pv.post_id, 'video_id', pv.video_id,
             'videos', (SELECT jsonb_build_object(
                          'id', v.id, 'state', v.state, 'current_version', v.current_version,
                          'video_versions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                                 'version_no', vv.version_no, 'width', vv.width, 'height', vv.height,
                                                 'declared_duration_s', vv.declared_duration_s,
                                                 'has_audio', vv.has_audio) ORDER BY vv.version_no), '[]'::jsonb)
                                               FROM public.video_versions vv WHERE vv.video_id = v.id))
                          FROM public.videos v WHERE v.id = pv.video_id))
           ORDER BY pv.post_id, pv.video_id), '[]'::jsonb) INTO _v
      FROM public.post_videos pv WHERE pv.post_id = ANY(_posts);
    _out := _out || jsonb_build_object('videos', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  IF cardinality(coalesce(_author_ids, '{}')) > 0 THEN
    BEGIN                                                                   -- ⚑ contributorScore (authors)
      SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.user_id), '[]'::jsonb) INTO _v
        FROM public.get_contributor_scores(
               (SELECT array_agg(DISTINCT x) FROM unnest(_author_ids) x WHERE x IS NOT NULL)) s;
      _out := _out || jsonb_build_object('scores', _v);
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;
  IF _credits THEN
    BEGIN                                                                   -- ⚑ photoOldCredit (web only)
      SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.post_id, c.ord), '[]'::jsonb) INTO _v
        FROM public.post_photo_credit_for(_posts) c;
      _out := _out || jsonb_build_object('credits', _v);
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  RETURN _out;
END
$fn$;
COMMENT ON FUNCTION public.get_feed_extras(uuid[], uuid[], boolean) IS
  '20261124_5300 N6-2: every extra read of a feed page (names, badges, roles, reactions, friendships, views, tags + tagged names, photos, videos, scores, old-photo credits) in ONE answer. SECURITY INVOKER: the caller''s own rights and row rules, same as the separate requests. A failed part is left out (the app then asks for it alone).';
REVOKE ALL ON FUNCTION public.get_feed_extras(uuid[], uuid[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_feed_extras(uuid[], uuid[], boolean) TO authenticated;

DO $post$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.get_feed_extras(uuid[],uuid[],boolean)'::regprocedure
                    AND NOT prosecdef AND proconfig = ARRAY['search_path=""'])
     OR has_function_privilege('anon', 'public.get_feed_extras(uuid[],uuid[],boolean)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.get_feed_extras(uuid[],uuid[],boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'N6-5300-POST: get_feed_extras not as intended';
  END IF;
  RAISE NOTICE 'N6-5300: get_feed_extras created (INVOKER, search_path '''', authenticated only)';
END
$post$;

COMMIT;

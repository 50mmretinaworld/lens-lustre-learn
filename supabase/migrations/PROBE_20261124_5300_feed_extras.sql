-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261124_5300 get_feed_extras. WRITES NOTHING (ROLLBACK). FAILS before apply.
--   A1  structure + grants: SECURITY INVOKER, search_path '', authenticated only, never anon
--   A2  for up to 3 real members (as the member: role authenticated + their JWT claims) and a realistic page
--       (their 10 newest visible posts + up to 5 tagged posts + up to 5 video posts),
--       every part is present (videos/credits only where the lane has them) and EACH EQUALS the separate request
--       the app makes today (same table / same function, same rules), the tagged people's names included
--   A3  signed out (no JWT), no ids, > 50 ids: an empty answer
-- Prints counts and timings only; no member id, no content.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

DO $p$
DECLARE
  _m        uuid;
  _a        jsonb;
  _part     text;
  _want     jsonb;
  _posts    uuid[];
  _authors  uuid[];
  _people   uuid[];
  _members  integer := 0;
  _checked  integer := 0;
  _nposts   integer := 0;
  _ntagged  integer := 0;
  _t        timestamptz;
  _ms       numeric := 0;
  _has_vid  boolean := to_regclass('public.post_videos') IS NOT NULL;
  _has_cred boolean := to_regprocedure('public.post_photo_credit_for(uuid[])') IS NOT NULL;
  _parts    text[];
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  IF to_regprocedure('public.get_feed_extras(uuid[],uuid[],boolean)') IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL A1: 5300 not applied';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.get_feed_extras(uuid[],uuid[],boolean)'::regprocedure
                    AND NOT prosecdef AND proconfig = ARRAY['search_path=""'])
     OR has_function_privilege('anon', 'public.get_feed_extras(uuid[],uuid[],boolean)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.get_feed_extras(uuid[],uuid[],boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: not INVOKER / search_path / grants as intended';
  END IF;

  _parts := ARRAY['tags','profile_ids','profiles','badges','roles','reactions','friendships','view_counts','media','scores'];
  IF _has_vid THEN _parts := _parts || 'videos'; END IF;
  IF _has_cred THEN _parts := _parts || 'credits'; END IF;

  -- A3: signed out / nothing / too many
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '{}', true);
  IF public.get_feed_extras(ARRAY[gen_random_uuid()], ARRAY[gen_random_uuid()], true) <> '{}'::jsonb THEN
    RAISE EXCEPTION 'PROBE FAIL A3: signed out did not get an empty answer';
  END IF;

  -- A2: the busiest members of the last 7 days, else the oldest profiles
  FOR _m IN
    SELECT u FROM (
      (SELECT fe.user_id AS u FROM public.feed_events fe
        WHERE fe.created_at > now() - interval '7 days' AND fe.user_id IS NOT NULL
        GROUP BY fe.user_id ORDER BY count(*) DESC LIMIT 3)
      UNION ALL
      (SELECT p.id FROM public.profiles p ORDER BY p.created_at LIMIT 3)
    ) s LIMIT 3
  LOOP
    _members := _members + 1;
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _m::text, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    IF public.get_feed_extras('{}'::uuid[], '{}'::uuid[], true) <> '{}'::jsonb
       OR public.get_feed_extras((SELECT array_agg(gen_random_uuid()) FROM generate_series(1, 51)), '{}'::uuid[], true) <> '{}'::jsonb THEN
      RESET ROLE;
      RAISE EXCEPTION 'PROBE FAIL A3: no ids / 51 ids did not get an empty answer';
    END IF;

    -- a realistic page AS THE MEMBER SEES IT (RLS): newest posts + tagged + video + photo-graph posts
    SELECT array_agg(DISTINCT id) INTO _posts FROM (
      (SELECT po.id FROM public.posts po ORDER BY po.created_at DESC LIMIT 10)
      UNION ALL (SELECT t.post_id FROM public.post_tags t WHERE t.status IN ('pending','approved')
                  ORDER BY t.created_at DESC LIMIT 5)
    ) s;
    IF _has_vid THEN
      EXECUTE 'SELECT array_agg(DISTINCT x) FROM (SELECT unnest($1) AS x UNION ALL
                 (SELECT pv.post_id FROM public.post_videos pv ORDER BY pv.post_id LIMIT 5)) s'
        INTO _posts USING coalesce(_posts, '{}'::uuid[]);
    END IF;
    IF _posts IS NULL OR cardinality(_posts) = 0 THEN RESET ROLE; CONTINUE; END IF;
    SELECT array_agg(DISTINCT po.user_id) INTO _authors FROM public.posts po WHERE po.id = ANY(_posts);
    _nposts := _nposts + cardinality(_posts);

    _t := clock_timestamp();
    _a := public.get_feed_extras(_posts, _authors, true);
    _ms := _ms + extract(epoch FROM clock_timestamp() - _t)::numeric * 1000;

    FOREACH _part IN ARRAY _parts LOOP
      IF NOT (_a ? _part) THEN
        RESET ROLE;
        RAISE EXCEPTION 'PROBE FAIL A2: member % of the sample: part % is missing (it failed inside get_feed_extras)', _members, _part;
      END IF;
    END LOOP;

    -- authors + tagged people, exactly as the app would ask for names
    SELECT array_agg(DISTINCT u) INTO _people FROM (
      SELECT unnest(_authors) AS u
      UNION SELECT t.tagged_user_id FROM public.post_tags t WHERE t.post_id = ANY(_posts) AND t.status IN ('pending','approved')
    ) s;
    _ntagged := _ntagged + (SELECT count(*) FROM public.post_tags t WHERE t.post_id = ANY(_posts) AND t.status IN ('pending','approved'));

    FOREACH _part IN ARRAY _parts LOOP
      _want := CASE _part
        WHEN 'tags'        THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('post_id', t.post_id, 'tagged_user_id', t.tagged_user_id,
                                                           'status', t.status) ORDER BY t.post_id, t.tagged_user_id, t.id), '[]'::jsonb)
                                   FROM public.post_tags t WHERE t.post_id = ANY(_posts) AND t.status IN ('pending','approved'))
        WHEN 'profile_ids' THEN (SELECT jsonb_agg(x ORDER BY x) FROM unnest(_people) x)
        WHEN 'profiles'    THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'avatar_url', p.avatar_url,
                                                           'custom_url', p.custom_url, 'last_active_at', p.last_active_at) ORDER BY p.id), '[]'::jsonb)
                                   FROM public.profiles_public_data p WHERE p.id = ANY(_people))
        WHEN 'badges'      THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('user_id', b.user_id, 'badge_type', b.badge_type)
                                                           ORDER BY b.user_id, b.badge_type), '[]'::jsonb)
                                   FROM public.user_badges b WHERE b.user_id = ANY(_people))
        WHEN 'roles'       THEN (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.user_id, r.role), '[]'::jsonb)
                                   FROM public.get_public_roles_for_users(_people) r)
        WHEN 'reactions'   THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('post_id', r.post_id, 'reaction_type', r.reaction_type,
                                                           'user_id', r.user_id) ORDER BY r.post_id, r.user_id, r.reaction_type), '[]'::jsonb)
                                   FROM public.post_reactions r WHERE r.post_id = ANY(_posts))
        WHEN 'friendships' THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('requester_id', f.requester_id, 'addressee_id', f.addressee_id,
                                                           'status', f.status) ORDER BY f.requester_id, f.addressee_id), '[]'::jsonb)
                                   FROM public.friendships f WHERE f.requester_id = _m OR f.addressee_id = _m)
        WHEN 'view_counts' THEN (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.post_id), '[]'::jsonb) FROM public.get_post_view_counts(_posts) c)
        WHEN 'media'       THEN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.post_id, x.ord), '[]'::jsonb) FROM public.post_media_for(_posts) x)
        WHEN 'scores'      THEN (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.user_id), '[]'::jsonb) FROM public.get_contributor_scores(_authors) s)
        ELSE NULL
      END;
      IF _part = 'videos' THEN
        EXECUTE $q$
          SELECT coalesce(jsonb_agg(jsonb_build_object('post_id', pv.post_id, 'video_id', pv.video_id,
                   'videos', (SELECT jsonb_build_object('id', v.id, 'state', v.state, 'current_version', v.current_version,
                                'video_versions', (SELECT coalesce(jsonb_agg(jsonb_build_object('version_no', vv.version_no,
                                   'width', vv.width, 'height', vv.height, 'declared_duration_s', vv.declared_duration_s,
                                   'has_audio', vv.has_audio) ORDER BY vv.version_no), '[]'::jsonb)
                                   FROM public.video_versions vv WHERE vv.video_id = v.id))
                              FROM public.videos v WHERE v.id = pv.video_id)) ORDER BY pv.post_id, pv.video_id), '[]'::jsonb)
            FROM public.post_videos pv WHERE pv.post_id = ANY($1)$q$ INTO _want USING _posts;
      ELSIF _part = 'credits' THEN
        EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.post_id, c.ord), ''[]''::jsonb) FROM public.post_photo_credit_for($1) c'
          INTO _want USING _posts;
      END IF;
      IF _a -> _part IS DISTINCT FROM _want THEN
        RESET ROLE;
        RAISE EXCEPTION 'PROBE FAIL A2: member % of the sample: part % differs from the separate request', _members, _part;
      END IF;
      _checked := _checked + 1;
    END LOOP;
    RESET ROLE;
  END LOOP;

  IF _members = 0 THEN
    RAISE NOTICE 'FEEDEXTRAS5300 PASS (structure only, lane %): no member to exercise', current_setting('p32.lane');
  ELSE
    RAISE NOTICE 'FEEDEXTRAS5300 PASS (lane %): A1–A3 hold; % members, % posts, % tags, % part answers equal the separate requests (videos %, credits %); one answer avg % ms',
      current_setting('p32.lane'), _members, _nposts, _ntagged, _checked, _has_vid, _has_cred, round(_ms / _members, 1);
  END IF;
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261124_5210 get_app_start + my_profile (N6-3). WRITES NOTHING (ROLLBACK). FAILS before apply (no my_profile).
--   A1  structure + grants: SECURITY INVOKER, search_path '', authenticated only, never anon
--   A2  for up to 3 real members (as the member: role authenticated + their JWT claims), all 13 parts are present
--       and EACH EQUALS the separate request the app makes today (same function / same read, same rules)
--   A3  signed out (no JWT): an empty answer
-- Prints counts and timings only; no member id, no content.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

DO $p$
DECLARE
  _m       uuid;
  _a       jsonb;
  _part    text;
  _want    jsonb;
  _members integer := 0;
  _checked integer := 0;
  _t       timestamptz;
  _ms      numeric := 0;
  _parts   constant text[] := ARRAY['features','message_allowed','account_state','admin_ids','me','blocked',
                                    'categories','trending','stories_bar','my_stories','drafts','bell','gift_unread','my_profile'];
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  IF to_regprocedure('public.get_app_start(integer,text[])') IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL A1: 5200 not applied';
  END IF;
  IF position('my_profile' IN pg_get_functiondef('public.get_app_start(integer,text[])'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'PROBE FAIL A1: 5210 not applied (no my_profile part)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.get_app_start(integer,text[])'::regprocedure
                    AND NOT prosecdef AND proconfig = ARRAY['search_path=""'])
     OR has_function_privilege('anon', 'public.get_app_start(integer,text[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.get_app_start(integer,text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: not INVOKER / search_path / grants as intended';
  END IF;

  -- A3: signed out
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '{}', true);
  IF public.get_app_start(20, ARRAY['friend_request']) <> '{}'::jsonb THEN
    RAISE EXCEPTION 'PROBE FAIL A3: signed out did not get an empty answer';
  END IF;

  -- A2: the busiest members of the last 7 days (realistic: bell rows, stories, blocks), else the oldest profiles
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
    _t := clock_timestamp();
    _a := public.get_app_start(20, ARRAY['friend_request']);
    _ms := _ms + extract(epoch FROM clock_timestamp() - _t)::numeric * 1000;

    FOREACH _part IN ARRAY _parts LOOP
      IF NOT (_a ? _part) THEN
        RESET ROLE;
        RAISE EXCEPTION 'PROBE FAIL A2: member % of the sample: part % is missing (it failed inside get_app_start)', _members, _part;
      END IF;
    END LOOP;

    -- each part = the separate request, made here the same way the app makes it (as the member)
    FOREACH _part IN ARRAY ARRAY['features','message_allowed','account_state','trending','stories_bar','my_stories',
                                 'groups','blocked','categories','drafts','admin_ids','gift_unread','friend_requests','me','my_profile'] LOOP
      _want := CASE _part
        WHEN 'features'        THEN public.features_allowed_me()
        WHEN 'message_allowed' THEN to_jsonb(public.message_allowed_me())
        WHEN 'account_state'   THEN to_jsonb(public.my_account_state())
        WHEN 'trending'        THEN public.get_trending_week()
        WHEN 'stories_bar'     THEN (SELECT coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) FROM public.get_feed_stories_bar() s)
        WHEN 'my_stories'      THEN (SELECT coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) FROM public.get_user_stories(_m) s)
        WHEN 'groups'          THEN (SELECT coalesce(jsonb_agg(to_jsonb(n)), '[]'::jsonb)
                                       FROM public.get_my_unread_notifications_grouped(20, ARRAY['friend_request']) n)
        WHEN 'blocked'         THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('blocked_id', b.blocked_id, 'created_at', b.created_at)
                                                               ORDER BY b.created_at DESC), '[]'::jsonb)
                                       FROM public.user_blocks b WHERE b.blocker_id = _m)
        WHEN 'categories'      THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('slug', c.slug, 'name', c.name, 'icon_name', c.icon_name,
                                                               'sort_order', c.sort_order, 'is_active', c.is_active)
                                                               ORDER BY c.sort_order ASC), '[]'::jsonb)
                                       FROM public.categories c WHERE c.is_active = true)
        WHEN 'drafts'          THEN (SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.updated_at DESC), '[]'::jsonb) FROM public.post_drafts d)
        WHEN 'admin_ids'       THEN (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM public.get_public_role_user_ids('admin') x)
        WHEN 'gift_unread'     THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'amount', g.amount, 'reason', g.reason,
                                                               'created_at', g.created_at) ORDER BY g.created_at DESC), '[]'::jsonb)
                                       FROM public.gift_announcements g WHERE g.user_id = _m AND g.is_read = false)
        WHEN 'friend_requests' THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'requester_id', f.requester_id,
                                                               'created_at', f.created_at) ORDER BY f.created_at DESC), '[]'::jsonb)
                                       FROM (SELECT * FROM public.friendships f0 WHERE f0.addressee_id = _m AND f0.status = 'pending'
                                              ORDER BY f0.created_at DESC LIMIT 10) f)
        WHEN 'me'              THEN (SELECT jsonb_build_object('is_banned', p.is_banned, 'privacy_settings', p.privacy_settings)
                                       FROM public.profiles p WHERE p.id = _m)
        WHEN 'my_profile'      THEN (SELECT jsonb_build_object('full_name', p.full_name, 'avatar_url', p.avatar_url, 'bio', p.bio,
                                       'portfolio_url', p.portfolio_url, 'photography_interests', p.photography_interests,
                                       'created_at', p.created_at, 'facebook_url', p.facebook_url, 'instagram_url', p.instagram_url,
                                       'twitter_url', p.twitter_url, 'youtube_url', p.youtube_url, 'website_url', p.website_url,
                                       'pronouns', p.pronouns, 'current_city', p.current_city, 'workplace', p.workplace,
                                       'education', p.education, 'custom_url', p.custom_url)
                                       FROM public.profiles_public_data p WHERE p.id = _m)
      END;
      IF (CASE WHEN _part IN ('groups', 'friend_requests') THEN _a -> 'bell' -> _part ELSE _a -> _part END) IS DISTINCT FROM _want THEN
        RESET ROLE;
        RAISE EXCEPTION 'PROBE FAIL A2: member % of the sample: part % differs from the separate request', _members, _part;
      END IF;
      _checked := _checked + 1;
    END LOOP;
    RESET ROLE;
  END LOOP;

  IF _members = 0 THEN
    RAISE NOTICE 'APPSTART5210 PASS (structure only, lane %): no member to exercise', current_setting('p32.lane');
  ELSE
    RAISE NOTICE 'APPSTART5210 PASS (lane %): A1–A3 hold; % members, % part answers equal the separate requests; one answer avg % ms',
      current_setting('p32.lane'), _members, _checked, round(_ms / _members, 1);
  END IF;
END
$p$;

ROLLBACK;

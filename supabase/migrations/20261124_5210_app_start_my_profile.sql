-- ═══════════════════════════════════════════════════════════════════════════
-- 20261124_5210 · N6-3: the start-up answer also carries the member's OWN profile (part "my_profile").
-- Lanes: staging, production. Requires 20261124_5200 (get_app_start) applied.
--
-- Measured (UI harness, 24 Nov, after N6-1/N6-2): every signed-in screen still read the member's own profile twice
-- on its own — the bottom bar's avatar (MobileBottomNav) and the profile core (useProfileData → profile card,
-- sidebar, menus). Both read profiles_public_data for the member's own id; the new part is that same read (same
-- columns, same view, the member's own rights), so both are answered by the one start-up request.
--
-- The function below is 20261124_5200's, UNCHANGED, plus the one part at the end (CREATE OR REPLACE; same
-- signature, same INVOKER / search_path / grants). Rollback (back to 5200's body):
-- supabase/rollback/20261124_5210_app_start_my_profile_ROLLBACK.sql. PROBE: PROBE_20261124_5210_app_start_my_profile.sql
--
-- ── 5200's header, kept: ──
-- 20261124_5200 · N6-1: ONE start-up request instead of ~15 (Owner 24 Nov: "go on" — close the gap to Meta).
--
-- Measured (UI harness, real app code, 24 Nov): every signed-in screen sent ~15 separate start-up reads (switches,
-- messages allowed, account state, admin list, banned flag, own privacy, blocked members, categories, trending,
-- stories row, own stories, drafts, bell ×3, gift pop-up). Each is ~0.2 s of travel from India.
-- get_app_start() answers all of them in one round trip.
--
-- ⚠ SECURITY INVOKER ON PURPOSE. It runs with the CALLER's rights, exactly like the separate requests it replaces:
-- every table read below goes through the same row-level security the app's direct reads go through, and every
-- function it calls is the same one the app already calls. It can never return anything the member could not
-- already read with those requests. Each part is in its own exception block: a part that fails is LEFT OUT, and the
-- app asks for that part the old way.
--
-- Not re-runnable as an apply (PRE-002). Rollback: supabase/rollback/20261124_5200_app_start_ROLLBACK.sql
-- PROBE: supabase/migrations/PROBE_20261124_5200_app_start.sql (every part equals the separate request, real members).
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
  IF to_regprocedure('public.get_app_start(integer,text[])') IS NULL THEN
    RAISE EXCEPTION 'N6-5210-PRE-001: 20261124_5200 (get_app_start) is not applied on this lane — apply it first';
  END IF;
  IF position('my_profile' IN pg_get_functiondef('public.get_app_start(integer,text[])'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'N6-5210-PRE-002: already applied — roll back first';
  END IF;
  IF to_regclass('public.profiles_public_data') IS NULL THEN
    RAISE EXCEPTION 'N6-5210-PRE-003: profiles_public_data is missing';
  END IF;
END
$pre$;

CREATE OR REPLACE FUNCTION public.get_app_start(_bell_limit integer DEFAULT 20, _bell_exclude text[] DEFAULT '{}')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $fn$
DECLARE
  _uid uuid := (SELECT auth.uid());
  _out jsonb := '{}'::jsonb;
  _v   jsonb;
BEGIN
  IF _uid IS NULL THEN
    RETURN _out;   -- signed out: nothing to answer; the app keeps its signed-out path
  END IF;

  -- The ⚑ comment on each part names the app reader it replaces (and therefore the request it must equal).
  BEGIN _out := _out || jsonb_build_object('features', public.features_allowed_me());          -- ⚑ useFeatureAllowed
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN _out := _out || jsonb_build_object('message_allowed', public.message_allowed_me());   -- ⚑ messages/nav
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN _out := _out || jsonb_build_object('account_state', public.my_account_state());       -- ⚑ useMyAccountState
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ adminBrand
    SELECT coalesce(jsonb_agg(x), '[]'::jsonb) INTO _v FROM public.get_public_role_user_ids(_role => 'admin') x;
    _out := _out || jsonb_build_object('admin_ids', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ useIsBanned + presence/online
    SELECT jsonb_build_object('is_banned', p.is_banned, 'privacy_settings', p.privacy_settings) INTO _v
      FROM public.profiles p WHERE p.id = _uid;
    _out := _out || jsonb_build_object('me', _v);   -- JSON null when the member has no row (same as maybeSingle)
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ useBlockedUsers
    SELECT coalesce(jsonb_agg(jsonb_build_object('blocked_id', b.blocked_id, 'created_at', b.created_at)
                              ORDER BY b.created_at DESC), '[]'::jsonb) INTO _v
      FROM public.user_blocks b WHERE b.blocker_id = _uid;
    _out := _out || jsonb_build_object('blocked', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ useCategories
    SELECT coalesce(jsonb_agg(jsonb_build_object('slug', c.slug, 'name', c.name, 'icon_name', c.icon_name,
                                                 'sort_order', c.sort_order, 'is_active', c.is_active)
                              ORDER BY c.sort_order ASC), '[]'::jsonb) INTO _v
      FROM public.categories c WHERE c.is_active = true;
    _out := _out || jsonb_build_object('categories', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN _out := _out || jsonb_build_object('trending', public.get_trending_week());          -- ⚑ useTrendingWeek
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ storyData.fetchStoryBar
    SELECT coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) INTO _v FROM public.get_feed_stories_bar() s;
    _out := _out || jsonb_build_object('stories_bar', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ storyData.fetchUserStories(me)
    SELECT coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) INTO _v FROM public.get_user_stories(_user_id => _uid) s;
    _out := _out || jsonb_build_object('my_stories', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ usePostDrafts (own rows by RLS)
    SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.updated_at DESC), '[]'::jsonb) INTO _v FROM public.post_drafts d;
    _out := _out || jsonb_build_object('drafts', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ useNotificationsQuery (3 reads)
    _out := _out || jsonb_build_object('bell', jsonb_build_object(
      'friend_requests', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'requester_id', f.requester_id,
                                                                       'created_at', f.created_at)
                                                    ORDER BY f.created_at DESC), '[]'::jsonb)
                            FROM (SELECT * FROM public.friendships f0
                                   WHERE f0.addressee_id = _uid AND f0.status = 'pending'
                                   ORDER BY f0.created_at DESC LIMIT 10) f),
      'gifts', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'amount', g.amount, 'reason', g.reason,
                                                             'created_at', g.created_at, 'expires_at', g.expires_at)
                                          ORDER BY g.created_at DESC), '[]'::jsonb)
                  FROM (SELECT * FROM public.gift_announcements g0
                         WHERE g0.user_id = _uid AND g0.is_read = false AND g0.is_expired = false
                         ORDER BY g0.created_at DESC LIMIT 10) g),
      'groups', (SELECT coalesce(jsonb_agg(to_jsonb(n)), '[]'::jsonb)
                   FROM public.get_my_unread_notifications_grouped(_bell_limit, _bell_exclude) n)));
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ GiftCelebrationModal
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'amount', g.amount, 'reason', g.reason,
                                                 'created_at', g.created_at)
                              ORDER BY g.created_at DESC), '[]'::jsonb) INTO _v
      FROM public.gift_announcements g WHERE g.user_id = _uid AND g.is_read = false;
    _out := _out || jsonb_build_object('gift_unread', _v);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN                                                                                       -- ⚑ useProfileData core + MobileBottomNav (5210)
    SELECT jsonb_build_object('full_name', p.full_name, 'avatar_url', p.avatar_url, 'bio', p.bio,
             'portfolio_url', p.portfolio_url, 'photography_interests', p.photography_interests,
             'created_at', p.created_at, 'facebook_url', p.facebook_url, 'instagram_url', p.instagram_url,
             'twitter_url', p.twitter_url, 'youtube_url', p.youtube_url, 'website_url', p.website_url,
             'pronouns', p.pronouns, 'current_city', p.current_city, 'workplace', p.workplace,
             'education', p.education, 'custom_url', p.custom_url) INTO _v
      FROM public.profiles_public_data p WHERE p.id = _uid;
    _out := _out || jsonb_build_object('my_profile', _v);   -- JSON null when no row (same as maybeSingle)
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN _out;
END
$fn$;
COMMENT ON FUNCTION public.get_app_start(integer, text[]) IS
  '20261124_5200 N6-1 + 5210 N6-3 (my_profile): every start-up read of a signed-in screen in ONE answer. SECURITY INVOKER: the caller''s own rights and row rules, same as the separate requests. A failed part is left out (the app then asks for it alone).';
REVOKE ALL ON FUNCTION public.get_app_start(integer, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_app_start(integer, text[]) TO authenticated;

DO $post$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.get_app_start(integer,text[])'::regprocedure
                    AND NOT prosecdef AND proconfig = ARRAY['search_path=""'])
     OR has_function_privilege('anon', 'public.get_app_start(integer,text[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.get_app_start(integer,text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'N6-5210-POST: get_app_start not as intended';
  END IF;
  IF position('my_profile' IN pg_get_functiondef('public.get_app_start(integer,text[])'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'N6-5210-POST: my_profile part missing';
  END IF;
  RAISE NOTICE 'N6-5210: get_app_start now also answers my_profile (INVOKER, search_path '''', authenticated only)';
END
$post$;

COMMIT;

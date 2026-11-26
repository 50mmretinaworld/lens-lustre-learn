-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBE · 20261126_6000 premium members. WRITES NOTHING (everything ends in ROLLBACK). FAILS before apply.
--   A1  structure: citation column + 140 check; featured_photos with RLS, SELECT-only for anon/authenticated;
--       set_featured_post DEFINER, search_path '', authenticated only (never anon); get_premium_members DEFINER,
--       search_path '', anon + authenticated; the unverify trigger exists.
--   A2  get_premium_members as a signed-out visitor (anon): rows = verified members minus admins minus banned /
--       suspended; never an admin; every photo is a PUBLIC post of that member.
--   A3  as a real Verified member (authenticated + JWT): mark photo 1 → listed as Featured; mark photo 2 → it
--       REPLACES photo 1 (still one row); unmark → gone. Another member's post and a non-public post are refused.
--   A4  as a real NON-verified member: marking is refused.
--   A5  citation: set → the list shows it as the line; 141 letters → refused by the check.
--   A6  removing the Verified badge removes the Featured mark (trigger).
-- Prints counts only; no member id, no content.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

DO $p$
DECLARE
  _v        uuid;   -- a verified, non-admin member with ≥ 2 public photo posts
  _p1       uuid;
  _p2       uuid;
  _other    uuid;   -- a public photo post of somebody else
  _priv     uuid;   -- a non-public post of _v (may be null)
  _plain    uuid;   -- a non-verified member with a public photo post
  _plain_p  uuid;
  _n_expect integer;
  _n_got    integer;
  _bad      integer;
  _r        uuid;
  _ok       boolean;
  _list     jsonb;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  -- A1 ── structure ──────────────────────────────────────────────────────────────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'user_badges' AND column_name = 'citation') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: user_badges.citation missing (6000 not applied)';
  END IF;
  IF to_regclass('public.featured_photos') IS NULL THEN RAISE EXCEPTION 'PROBE FAIL A1: featured_photos missing'; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.featured_photos'::regclass) THEN
    RAISE EXCEPTION 'PROBE FAIL A1: featured_photos RLS off';
  END IF;
  IF has_table_privilege('anon', 'public.featured_photos', 'INSERT')
     OR has_table_privilege('authenticated', 'public.featured_photos', 'INSERT')
     OR has_table_privilege('authenticated', 'public.featured_photos', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.featured_photos', 'DELETE') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: featured_photos writable directly';
  END IF;
  IF NOT has_table_privilege('anon', 'public.featured_photos', 'SELECT') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: featured_photos not readable by visitors';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.set_featured_post(uuid)'::regprocedure
                    AND prosecdef AND proconfig @> ARRAY['search_path=""']) THEN
    RAISE EXCEPTION 'PROBE FAIL A1: set_featured_post not DEFINER with empty search_path';
  END IF;
  IF has_function_privilege('anon', 'public.set_featured_post(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: anon can run set_featured_post';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.set_featured_post(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: members cannot run set_featured_post';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.get_premium_members(integer)'::regprocedure
                    AND prosecdef AND proconfig @> ARRAY['search_path=""']) THEN
    RAISE EXCEPTION 'PROBE FAIL A1: get_premium_members not DEFINER with empty search_path';
  END IF;
  IF NOT has_function_privilege('anon', 'public.get_premium_members(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: visitors cannot read the list';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_clear_featured_on_unverify'
                    AND tgrelid = 'public.user_badges'::regclass) THEN
    RAISE EXCEPTION 'PROBE FAIL A1: unverify trigger missing';
  END IF;

  -- A2 ── the public list, as a signed-out visitor ──────────────────────────────────────────────────────────────
  SELECT count(*) INTO _n_expect
    FROM public.user_badges b JOIN public.profiles pr ON pr.id = b.user_id
   WHERE b.badge_type = 'verified'
     AND NOT coalesce(pr.is_banned, false) AND NOT coalesce(pr.is_suspended, false)
     AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = b.user_id AND r.role = 'admin');

  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '{}', true);
  SET LOCAL ROLE anon;
  SELECT coalesce(jsonb_agg(jsonb_build_object('u', m.user_id, 'p', m.post_id)), '[]'::jsonb) INTO _list
    FROM public.get_premium_members(200) m;
  RESET ROLE;

  _n_got := jsonb_array_length(_list);
  IF _n_got <> least(_n_expect, 200) THEN
    RAISE EXCEPTION 'PROBE FAIL A2: list has % rows, expected %', _n_got, least(_n_expect, 200);
  END IF;
  SELECT count(*) INTO _bad FROM jsonb_to_recordset(_list) AS m(u uuid, p uuid)
   WHERE EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = m.u AND r.role = 'admin');
  IF _bad > 0 THEN RAISE EXCEPTION 'PROBE FAIL A2: an admin account is listed'; END IF;
  SELECT count(*) INTO _bad FROM jsonb_to_recordset(_list) AS m(u uuid, p uuid) JOIN public.posts po ON po.id = m.p
   WHERE po.user_id <> m.u OR po.privacy <> 'public';
  IF _bad > 0 THEN RAISE EXCEPTION 'PROBE FAIL A2: % photos are not the member''s public posts', _bad; END IF;

  -- pick the members to exercise ────────────────────────────────────────────────────────────────────────────────
  SELECT b.user_id INTO _v
    FROM public.user_badges b
   WHERE b.badge_type = 'verified'
     AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = b.user_id AND r.role = 'admin')
     AND (SELECT count(*) FROM public.posts p WHERE p.user_id = b.user_id AND p.privacy = 'public' AND p.post_kind = 'member'
            AND coalesce(nullif(p.image_url, ''), p.image_urls[1]) IS NOT NULL) >= 2
   LIMIT 1;

  IF _v IS NULL THEN
    RAISE NOTICE 'PREMIUM6000 PASS (structure + list only, lane %): % listed; no verified member with 2 public photos to exercise A3–A6',
      current_setting('p32.lane'), _n_got;
    RETURN;
  END IF;

  SELECT p.id INTO _p1 FROM public.posts p WHERE p.user_id = _v AND p.privacy = 'public' AND p.post_kind = 'member'
     AND coalesce(nullif(p.image_url, ''), p.image_urls[1]) IS NOT NULL ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _p2 FROM public.posts p WHERE p.user_id = _v AND p.privacy = 'public' AND p.post_kind = 'member'
     AND coalesce(nullif(p.image_url, ''), p.image_urls[1]) IS NOT NULL AND p.id <> _p1 ORDER BY p.created_at DESC LIMIT 1;
  SELECT p.id INTO _other FROM public.posts p WHERE p.user_id <> _v AND p.privacy = 'public'
     AND coalesce(nullif(p.image_url, ''), p.image_urls[1]) IS NOT NULL LIMIT 1;
  SELECT p.id INTO _priv FROM public.posts p WHERE p.user_id = _v AND p.privacy <> 'public' LIMIT 1;
  SELECT p.user_id, p.id INTO _plain, _plain_p FROM public.posts p
   WHERE p.privacy = 'public' AND p.post_kind = 'member'
     AND coalesce(nullif(p.image_url, ''), p.image_urls[1]) IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.user_badges b WHERE b.user_id = p.user_id AND b.badge_type = 'verified')
   LIMIT 1;

  -- A3 ── as the Verified member ────────────────────────────────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _v::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  _r := public.set_featured_post(_p1);
  IF _r IS DISTINCT FROM _p1 THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL A3: marking photo 1 did not return it'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_premium_members(200) m WHERE m.user_id = _v AND m.post_id = _p1 AND m.is_featured) THEN
    RESET ROLE; RAISE EXCEPTION 'PROBE FAIL A3: photo 1 not shown as Featured';
  END IF;

  PERFORM public.set_featured_post(_p2);
  IF (SELECT count(*) FROM public.featured_photos f WHERE f.user_id = _v) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.featured_photos f WHERE f.user_id = _v AND f.post_id = _p2) THEN
    RESET ROLE; RAISE EXCEPTION 'PROBE FAIL A3: photo 2 did not replace photo 1';
  END IF;

  _ok := false;
  BEGIN PERFORM public.set_featured_post(_other); EXCEPTION WHEN insufficient_privilege THEN _ok := true; END;
  IF NOT _ok THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL A3: another member''s post was accepted'; END IF;

  IF _priv IS NOT NULL THEN
    _ok := false;
    BEGIN PERFORM public.set_featured_post(_priv); EXCEPTION WHEN insufficient_privilege THEN _ok := true; END;
    IF NOT _ok THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL A3: a non-public post was accepted'; END IF;
  END IF;

  _ok := false;
  BEGIN INSERT INTO public.featured_photos (user_id, post_id) VALUES (_v, _p1); EXCEPTION WHEN insufficient_privilege THEN _ok := true; END;
  IF NOT _ok THEN RESET ROLE; RAISE EXCEPTION 'PROBE FAIL A3: direct write to featured_photos was allowed'; END IF;

  PERFORM public.set_featured_post(NULL);
  IF EXISTS (SELECT 1 FROM public.featured_photos f WHERE f.user_id = _v) THEN
    RESET ROLE; RAISE EXCEPTION 'PROBE FAIL A3: unmark did not remove the mark';
  END IF;
  RESET ROLE;

  -- A4 ── as a member without the badge ─────────────────────────────────────────────────────────────────────────
  IF _plain IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _plain::text, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    _ok := false;
    BEGIN PERFORM public.set_featured_post(_plain_p); EXCEPTION WHEN insufficient_privilege THEN _ok := true; END;
    RESET ROLE;
    IF NOT _ok THEN RAISE EXCEPTION 'PROBE FAIL A4: a member without the badge could mark a photo'; END IF;
  END IF;

  -- A5 ── citation ─────────────────────────────────────────────────────────────────────────────────────────────
  UPDATE public.user_badges SET citation = 'PROBE line' WHERE user_id = _v AND badge_type = 'verified';
  IF NOT EXISTS (SELECT 1 FROM public.get_premium_members(200) m WHERE m.user_id = _v AND m.line = 'PROBE line' AND m.line_is_citation) THEN
    RAISE EXCEPTION 'PROBE FAIL A5: citation not used as the line';
  END IF;
  _ok := false;
  BEGIN
    UPDATE public.user_badges SET citation = repeat('x', 141) WHERE user_id = _v AND badge_type = 'verified';
  EXCEPTION WHEN check_violation THEN _ok := true;
  END;
  IF NOT _ok THEN RAISE EXCEPTION 'PROBE FAIL A5: a 141-letter line was accepted'; END IF;

  -- A6 ── badge removed → mark removed ─────────────────────────────────────────────────────────────────────────
  INSERT INTO public.featured_photos (user_id, post_id) VALUES (_v, _p1);  -- as the owner role (setup only)
  DELETE FROM public.user_badges WHERE user_id = _v AND badge_type = 'verified';
  IF EXISTS (SELECT 1 FROM public.featured_photos f WHERE f.user_id = _v) THEN
    RAISE EXCEPTION 'PROBE FAIL A6: Featured mark survived the badge removal';
  END IF;

  RAISE NOTICE 'PREMIUM6000 PASS (lane %): A1–A6 hold; % Premium Members listed for visitors',
    current_setting('p32.lane'), _n_got;
END
$p$;

ROLLBACK;

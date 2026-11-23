-- ═══════════════════════════════════════════════════════════
-- PROBE · 20261123_4600 feed order switch. WRITES NOTHING: every step runs in
-- one transaction that ends in ROLLBACK. FAILS before apply.
--
-- PASS = the structure is in place AND the rules hold when exercised as a
-- real member (auth.uid() set through the JWT claims, role authenticated):
--   R1  switch Off                    → For you = Fair mix (no 'chronological' row)
--   R2  Selected, member on the list  → For you = newest first: every row
--                                       'chronological', created_at never rises
--   R3  page 2 continues below page 1 → no repeat, nothing newer than page 1's last
--   R4  Selected, member NOT on list  → still the Fair mix
--   R5  All members                   → newest first for the member not on the list
--   R6  Following tab                 → served as before (no error)
--   R7  no API role can call feed_newest_timeline; get_feed_page authenticated only
-- Prints counts only — no member data.
-- ═══════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _a     uuid;   -- member A (put on the Selected list)
  _b     uuid;   -- member B (not on the list)
  _f     constant text := 'public.get_feed_page(text,boolean,text,integer,integer,integer,text[])';
  _t     constant text := 'public.feed_newest_timeline(uuid[],integer,text[])';
  _n     integer;
  _chron integer;
  _rise  integer;
  _last  timestamptz;
  _ids   uuid[];
  _ts    timestamptz[];
  _p1    integer;
  _n2    integer;
  _rep   integer;
  _newer integer;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  -- ── structure ──────────────────────────────────────────────
  IF to_regprocedure(_t) IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL: feed_newest_timeline missing (4600 not applied)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.feature_access WHERE feature = 'feed_newest_first') THEN
    RAISE EXCEPTION 'PROBE FAIL: switch feed_newest_first missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = _t::regprocedure AND prosecdef AND proconfig = ARRAY['search_path=""'])
     OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = _f::regprocedure AND prosecdef AND proconfig = ARRAY['search_path=""']) THEN
    RAISE EXCEPTION 'PROBE FAIL: a function is not SECURITY DEFINER / search_path=""';
  END IF;
  -- R7
  IF has_function_privilege('anon', _t, 'EXECUTE') OR has_function_privilege('authenticated', _t, 'EXECUTE')
     OR has_function_privilege('service_role', _t, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL R7: an API role can call feed_newest_timeline';
  END IF;
  IF NOT has_function_privilege('authenticated', _f, 'EXECUTE') OR has_function_privilege('anon', _f, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL R7: get_feed_page grants changed';
  END IF;

  -- ── two real members who can see at least 12 public posts by others ──
  SELECT array_agg(x.id) INTO _ids FROM (
    SELECT pr.id FROM public.profiles pr
     WHERE (SELECT count(*) FROM public.posts p WHERE p.is_public AND p.user_id <> pr.id) >= 12
     ORDER BY pr.created_at LIMIT 2) x;
  IF coalesce(cardinality(_ids), 0) < 2 THEN
    RAISE NOTICE 'FNF4600 PASS (structure only, lane %): fewer than 2 members / 12 public posts to exercise the rules',
      current_setting('p32.lane');
    RETURN;
  END IF;
  _a := _ids[1]; _b := _ids[2];

  -- R1 · switch Off → Fair mix
  UPDATE public.feature_access SET mode = 'off' WHERE feature = 'feed_newest_first';
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _a::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*), count(*) FILTER (WHERE g.feed_tier = 'chronological') INTO _n, _chron
    FROM public.get_feed_page('for_you', false, 'probe4600-r1', 0, 10, 3, NULL) g;
  RESET ROLE;
  IF _n = 0 OR _chron > 0 THEN
    RAISE EXCEPTION 'PROBE FAIL R1: switch Off gave % rows, % chronological', _n, _chron;
  END IF;

  -- R2 · Selected, A on the list → newest first
  UPDATE public.feature_access SET mode = 'selected' WHERE feature = 'feed_newest_first';
  INSERT INTO public.feature_access_members (feature, user_id) VALUES ('feed_newest_first', _a) ON CONFLICT DO NOTHING;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _a::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT array_agg(g.id ORDER BY g.feed_pos), array_agg(g.created_at ORDER BY g.feed_pos),
         count(*) FILTER (WHERE g.feed_tier = 'chronological')
    INTO _ids, _ts, _chron
    FROM public.get_feed_page('for_you', false, 'probe4600-r2', 0, 10, 3, NULL) g;
  RESET ROLE;
  _n := coalesce(cardinality(_ids), 0);
  SELECT count(*) INTO _rise FROM generate_series(2, greatest(_n, 1)) i WHERE _ts[i] > _ts[i - 1];
  IF _n = 0 OR _chron <> _n OR _rise > 0 THEN
    RAISE EXCEPTION 'PROBE FAIL R2: Newest first gave % rows, % chronological, % out of order', _n, _chron, _rise;
  END IF;
  _p1 := _n;
  _last := _ts[_n];

  -- R3 · page 2 continues below page 1
  SET LOCAL ROLE authenticated;
  SELECT count(*), count(*) FILTER (WHERE g.id = ANY (_ids)), count(*) FILTER (WHERE g.created_at > _last)
    INTO _n2, _rep, _newer
    FROM public.get_feed_page('for_you', false, 'probe4600-r2', _n, 10, 0, NULL) g;
  RESET ROLE;
  IF _rep > 0 OR _newer > 0 THEN
    RAISE EXCEPTION 'PROBE FAIL R3: page 2 has % repeats, % newer than page 1''s last', _rep, _newer;
  END IF;

  -- R4 · B is not on the list → Fair mix
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _b::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*), count(*) FILTER (WHERE g.feed_tier = 'chronological') INTO _n, _chron
    FROM public.get_feed_page('for_you', false, 'probe4600-r4', 0, 10, 3, NULL) g;
  RESET ROLE;
  IF _n = 0 OR _chron > 0 THEN
    RAISE EXCEPTION 'PROBE FAIL R4: a member not on the list got % chronological of % rows', _chron, _n;
  END IF;

  -- R5 · All members → B gets newest first
  UPDATE public.feature_access SET mode = 'everyone' WHERE feature = 'feed_newest_first';
  SET LOCAL ROLE authenticated;
  SELECT count(*), count(*) FILTER (WHERE g.feed_tier = 'chronological') INTO _n, _chron
    FROM public.get_feed_page('for_you', false, 'probe4600-r5', 0, 10, 3, NULL) g;
  RESET ROLE;
  IF _n = 0 OR _chron <> _n THEN
    RAISE EXCEPTION 'PROBE FAIL R5: All members gave % chronological of % rows', _chron, _n;
  END IF;

  -- R6 · Following tab still served
  SET LOCAL ROLE authenticated;
  PERFORM count(*) FROM public.get_feed_page('following', false, 'probe4600-r6', 0, 10, 0, NULL);
  RESET ROLE;

  RAISE NOTICE 'FNF4600 PASS (lane %): R1–R7 hold; page 1 % rows, page 2 % rows; switch now % (rolled back)',
    current_setting('p32.lane'), _p1, _n2,
    (SELECT mode FROM public.feature_access WHERE feature = 'feed_newest_first');
END
$p$;

ROLLBACK;

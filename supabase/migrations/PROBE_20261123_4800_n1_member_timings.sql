-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · N1 1b/1c/1d — time the slow member calls AS A REAL MEMBER, part by
-- part, inside ONE transaction that ends in ROLLBACK (get_feed_page writes its
-- delivery log; nothing is kept). Prints milliseconds and row counts only — no
-- member id, no content. The member: the one with the most feed events in the
-- last 7 days (a busy, realistic viewer). Applied only via apply-migration.yml.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';
SET LOCAL lock_timeout = '5s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _m    uuid;
  _t    timestamptz;
  _ms   numeric;
  _n    bigint;
  i     integer;
  r     record;
  _calls text[] := ARRAY[
    'feed_page_broadcast_p0|SELECT count(*) FROM public.get_feed_page(''for_you'', false, ''n1-4800-a'', 0, 10, 3, NULL)',
    'feed_page_broadcast_p1|SELECT count(*) FROM public.get_feed_page(''for_you'', false, ''n1-4800-a'', 10, 10, 0, NULL)',
    'feed_page_personal_p0|SELECT count(*) FROM public.get_feed_page(''for_you'', true, ''n1-4800-b'', 0, 10, 3, NULL)',
    'feed_page_following_p0|SELECT count(*) FROM public.get_feed_page(''following'', false, ''n1-4800-c'', 0, 10, 0, NULL)',
    'broadcast_feed_direct|SELECT count(*) FROM public.get_broadcast_feed(''{}''::uuid[], 10, 3, NULL::text[], ''n1-4800-d'')',
    'personal_feed_direct|SELECT count(*) FROM public.get_personal_feed(''{}''::uuid[], 10, 3, NULL::text[], ''n1-4800-e'')',
    'feed_candidates_pool|SELECT count(*) FROM public.feed_candidates(''session:n1-4800-f'', NULL::text[])',
    'bell_unread_grouped|SELECT count(*) FROM public.get_my_unread_notifications_grouped(20, ''{}''::text[])',
    'trending_week|SELECT length(public.get_trending_week()::text)::bigint',
    'stories_bar|SELECT count(*) FROM public.get_feed_stories_bar()'
  ];
  _c text;
  _name text;
  _sql text;
  _best numeric;
  _avg numeric;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  SELECT fe.user_id INTO _m FROM public.feed_events fe
   WHERE fe.created_at > now() - interval '7 days' AND fe.user_id IS NOT NULL
   GROUP BY fe.user_id ORDER BY count(*) DESC LIMIT 1;
  IF _m IS NULL THEN SELECT p.id INTO _m FROM public.profiles p ORDER BY p.created_at LIMIT 1; END IF;
  RAISE NOTICE 'N1T lane % · busy member chosen (id not printed) · unread notifications % · posts %',
    current_setting('p32.lane'),
    (SELECT count(*) FROM public.user_notifications n WHERE n.user_id = _m AND n.is_read = false),
    (SELECT count(*) FROM public.posts);

  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _m::text, 'role', 'authenticated')::text, true);

  FOREACH _c IN ARRAY _calls LOOP
    _name := split_part(_c, '|', 1);
    _sql  := substr(_c, length(_name) + 2);
    _best := NULL; _avg := 0;
    FOR i IN 1..3 LOOP
      _t := clock_timestamp();
      BEGIN
        IF _name <> 'feed_candidates_pool' THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
        EXECUTE _sql INTO _n;
        EXECUTE 'RESET ROLE';
      EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE NOTICE 'N1T|%|ERROR %', _name, left(SQLERRM, 120);
        EXIT;
      END;
      _ms := round(extract(epoch FROM clock_timestamp() - _t)::numeric * 1000, 1);
      _best := least(coalesce(_best, _ms), _ms);
      _avg := _avg + _ms / 3;
    END LOOP;
    IF _best IS NOT NULL THEN
      RAISE NOTICE 'N1T|%|best % ms|avg % ms|rows %', _name, _best, round(_avg, 1), _n;
    END IF;
  END LOOP;
END
$p$;

ROLLBACK;

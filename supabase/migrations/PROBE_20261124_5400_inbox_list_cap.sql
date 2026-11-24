-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261124_5400 inbox list cap 100 → 500. WRITES NOTHING (ROLLBACK). FAILS before apply.
--   A1  both functions carry the 500 cap, are still SECURITY DEFINER with search_path '', never anon
--   A2  for the 3 members with the MOST chats (as the member: role authenticated + JWT claims):
--       asking for 500 returns EVERY chat the list may show (= min(count, 500), counted directly), newest first,
--       no chat twice; asking for 30 still returns the newest 30 (the first 30 of the full answer)
-- Prints counts and timings only; no member id, no content.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

DO $p$
DECLARE
  _m       uuid;
  _all     jsonb;
  _first   jsonb;
  _want    integer;
  _got     integer;
  _members integer := 0;
  _biggest integer := 0;
  _t       timestamptz;
  _ms      numeric := 0;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  IF position('least(greatest(coalesce(_limit, 30), 1), 500)' IN pg_get_functiondef('public.message_my_conversations(text,integer,timestamptz)'::regprocedure)) = 0
     OR position('least(greatest(coalesce(_limit, 30), 1), 500)' IN pg_get_functiondef('public.admin_view_inbox(uuid,text,integer,timestamptz)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'PROBE FAIL A1: 5400 not applied (the list is still capped at 100)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.message_my_conversations(text,integer,timestamptz)'::regprocedure
                   AND prosecdef AND proconfig = ARRAY['search_path=""'])
     OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.admin_view_inbox(uuid,text,integer,timestamptz)'::regprocedure
                   AND prosecdef AND proconfig = ARRAY['search_path=""'])
     OR has_function_privilege('anon', 'public.message_my_conversations(text,integer,timestamptz)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.admin_view_inbox(uuid,text,integer,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL A1: definer / search_path / grants changed';
  END IF;

  FOR _m IN
    SELECT cm.user_id FROM public.conversation_members cm WHERE cm.folder = 'inbox'
     GROUP BY cm.user_id ORDER BY count(*) DESC LIMIT 3
  LOOP
    _members := _members + 1;
    -- the chats the list may show, counted directly (same rule as the function's WHERE)
    SELECT count(*) INTO _want
      FROM public.conversation_members cm JOIN public.conversations c ON c.id = cm.conversation_id
     WHERE cm.user_id = _m AND cm.folder = 'inbox'
       AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = 'sent' OR m.sender_id = _m));
    _want := least(_want, 500);
    _biggest := greatest(_biggest, _want);

    PERFORM set_config('request.jwt.claim.sub', _m::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _m::text, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    _t := clock_timestamp();
    _all := public.message_my_conversations('inbox', 500, NULL);
    _ms := _ms + extract(epoch FROM clock_timestamp() - _t)::numeric * 1000;
    _first := public.message_my_conversations('inbox', 30, NULL);
    RESET ROLE;

    _got := jsonb_array_length(_all);
    IF _got <> _want THEN
      RAISE EXCEPTION 'PROBE FAIL A2: member % of the sample: 500 asked, % returned, % expected', _members, _got, _want;
    END IF;
    IF (SELECT count(DISTINCT e ->> 'conversation_id') FROM jsonb_array_elements(_all) e) <> _got THEN
      RAISE EXCEPTION 'PROBE FAIL A2: member % of the sample: a chat appears twice', _members;
    END IF;
    -- tie-safe (a broadcast gives many chats the same last-message time): the 30 are all in the full list, and none
    -- is older than the full list's 30th chat
    IF jsonb_array_length(_first) <> least(30, _want)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(_first) f
                   WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(_all) a WHERE a ->> 'conversation_id' = f ->> 'conversation_id'))
       OR (_want >= 30 AND EXISTS (SELECT 1 FROM jsonb_array_elements(_first) f
                   WHERE coalesce((f ->> 'last_message_at')::timestamptz, '-infinity')
                         < coalesce((_all -> 29 ->> 'last_message_at')::timestamptz, '-infinity'))) THEN
      RAISE EXCEPTION 'PROBE FAIL A2: member % of the sample: the first 30 are not the newest 30 of the full list', _members;
    END IF;
  END LOOP;

  RAISE NOTICE 'INBOXCAP5400 PASS (lane %): A1–A2 hold; % members, largest inbox % chats returned in full; 500-answer avg % ms',
    current_setting('p32.lane'), _members, _biggest, round(_ms / greatest(_members, 1), 1);
END
$p$;

ROLLBACK;

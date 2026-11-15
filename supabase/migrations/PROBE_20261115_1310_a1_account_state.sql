-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1310 — A1 account state + guard. One transaction, ROLLBACK:
-- the states, switch flips, test hashtag, follows and log rows are thrown away.
-- Before 20261115_1310: FAIL (account_states missing). After: A1 PASS.
--   G1  every member-writable table (row rule or member-run DEFINER) is guarded
--       or on the passive list — none left out
--   G2  switch OFF: a member under review can still write (nothing changes yet)
--   G3  switch ON: under review → direct write refused (follows), ACCOUNT_UNDER_REVIEW
--   G4  switch ON: under review → write through a SECURITY DEFINER function refused
--       (follow_hashtag → hashtag_follows)
--   G5  switch ON: under review → passive write still works (search_recents)
--   G6  switch ON: an active member writes normally; service / cron work unaffected
--   G7  is_suspended alone also blocks (old flag folded into the one rule)
--   G8  a member cannot write account_states, cannot run admin_set_account_state
--   G9  admin_set_account_state: admin only, reason required, logged; log is append-only
--   G10 my_account_state(): 'under_review' for the reviewed member, 'active' otherwise
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

CREATE FUNCTION pg_temp.as_user(_uid uuid, _sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE _v text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
    SET LOCAL ROLE authenticated;
    IF _sql ~* '^\s*(insert|update|delete)' AND _sql !~* 'returning' THEN
      EXECUTE _sql; _v := 'written';
    ELSE
      EXECUTE _sql INTO _v;
    END IF;
    RAISE EXCEPTION 'PROBE_OK:%', coalesce(_v, '<no row>');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PROBE_OK:%' THEN RETURN 'ok ' || substr(SQLERRM, 10); END IF;
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 80);
  END;
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'A1 lane %', current_setting('p32.lane', true);
  IF to_regclass('public.account_states') IS NULL THEN
    RAISE EXCEPTION 'A1 FAIL: account_states missing — expected before 20261115_1310';
  END IF;

  -- G1 coverage
  WITH member_writable AS (
    SELECT p.tablename AS tbl FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
       AND p.roles && ARRAY['authenticated', 'public']::name[]
  ), guarded AS (
    SELECT c.relname AS tbl FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND t.tgname = 'zz_account_state_guard'
  )
  SELECT count(*) INTO _n FROM (SELECT DISTINCT tbl FROM member_writable) w
   WHERE w.tbl NOT IN (SELECT tbl FROM guarded)
     AND w.tbl NOT IN ('push_tokens', 'user_devices', 'user_notifications', 'notification_preferences',
       'feed_events', 'feed_signal_events', 'feed_hidden_posts', 'feed_muted_authors', 'feed_favourite_authors',
       'search_recents', 'profile_views', 'story_views', 'ad_impressions', 'ad_conversions', 'activity_logs',
       'lesson_progress', 'user_blocks', 'support_tickets', 'ticket_replies', 'email_send_log', 'email_send_state',
       'email_unsubscribe_tokens', 'suppressed_emails', 'newsletter_subscribers', 'ai_chat_usage',
       'account_states', 'account_state_log')
     AND EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND c.relname = w.tbl AND c.relkind IN ('r', 'p'));
  IF _n > 0 THEN _fail := _fail || format('G1 %s member-writable table(s) neither guarded nor passive', _n); END IF;
  SELECT count(*) INTO _n FROM pg_trigger WHERE tgname = 'zz_account_state_guard';
  RAISE NOTICE 'A1 G1 guarded tables=%', _n;

  -- members to test with: three active ones (not suspended / banned, no state row), one admin
  SELECT p.id INTO _m1 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id <> _m1 ORDER BY p.created_at LIMIT 1;
  SELECT p.id INTO _m3 FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND p.id NOT IN (_m1, _m2) ORDER BY p.created_at LIMIT 1;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' AND r.user_id NOT IN (_m1, _m2, _m3) LIMIT 1;
  IF _m1 IS NULL OR _m2 IS NULL OR _m3 IS NULL THEN RAISE EXCEPTION 'A1 FAIL: need three active members to test with'; END IF;
  DELETE FROM public.follows WHERE follower_id IN (_m1, _m2) AND following_id IN (_m2, _m3, _m1);
  BEGIN
    INSERT INTO public.hashtags (tag) VALUES ('a1probecheck') ON CONFLICT DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'A1 G4 note: could not create the test hashtag (%) — G4 uses an existing tag', SQLERRM;
  END;
  DELETE FROM public.hashtag_follows WHERE user_id = _m1;

  INSERT INTO public.account_states (user_id, state, reason) VALUES (_m1, 'under_review', 'A1 PROBE');

  -- G2 switch OFF
  UPDATE public.system_flags SET value = false WHERE key = 'account_state_guard';
  _r := pg_temp.as_user(_m1, format('INSERT INTO public.follows (follower_id, following_id) VALUES (%L, %L)', _m1, _m2));
  IF _r NOT LIKE 'ok%' THEN _fail := _fail || ('G2 switch OFF but the write was refused: ' || _r); END IF;
  DELETE FROM public.follows WHERE follower_id = _m1 AND following_id = _m2;

  -- G3–G5 switch ON, member under review
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  _r := pg_temp.as_user(_m1, format('INSERT INTO public.follows (follower_id, following_id) VALUES (%L, %L)', _m1, _m3));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('G3 direct write not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format('SELECT public.follow_hashtag(%L)::text',
          coalesce((SELECT tag FROM public.hashtags WHERE tag = 'a1probecheck'), (SELECT tag FROM public.hashtags ORDER BY tag LIMIT 1))));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('G4 DEFINER write not refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, format($q$INSERT INTO public.search_recents (user_id, item_type, item_id, title, url) VALUES (%L, 'user', 'x', 'A1 probe', '/x')$q$, _m1));
  IF _r NOT LIKE 'ok%' THEN _fail := _fail || ('G5 passive write refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m1, 'SELECT public.my_account_state()');
  IF _r <> 'ok under_review' THEN _fail := _fail || ('G10 reviewed member sees ' || _r); END IF;

  -- G6 active member + service work
  _r := pg_temp.as_user(_m2, format('INSERT INTO public.follows (follower_id, following_id) VALUES (%L, %L)', _m2, _m3));
  IF _r NOT LIKE 'ok%' THEN _fail := _fail || ('G6 active member refused: ' || _r); END IF;
  _r := pg_temp.as_user(_m2, 'SELECT public.my_account_state()');
  IF _r <> 'ok active' THEN _fail := _fail || ('G10 active member sees ' || _r); END IF;
  BEGIN
    INSERT INTO public.follows (follower_id, following_id) VALUES (_m1, _m2);   -- no JWT: service / cron path
  EXCEPTION WHEN OTHERS THEN _fail := _fail || ('G6 service path refused: ' || SQLERRM);
  END;

  -- G7 old suspended flag alone
  DELETE FROM public.account_states WHERE user_id = _m1;
  UPDATE public.profiles SET is_suspended = true WHERE id = _m2;
  _r := pg_temp.as_user(_m2, format('DELETE FROM public.follows WHERE follower_id = %L', _m2));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('G7 suspended member not refused: ' || _r); END IF;
  UPDATE public.profiles SET is_suspended = false WHERE id = _m2;

  -- G8 member cannot touch state
  _r := pg_temp.as_user(_m3, format($q$INSERT INTO public.account_states (user_id, state) VALUES (%L, 'active')$q$, _m3));
  IF _r LIKE 'ok%' THEN _fail := _fail || 'G8 member wrote account_states'::text; END IF;
  _r := pg_temp.as_user(_m3, format($q$SELECT public.admin_set_account_state(%L, 'under_review', 'x')$q$, _m2));
  IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('G8 member ran admin_set_account_state: ' || _r); END IF;

  -- G9 admin path
  IF _admin IS NULL THEN
    RAISE NOTICE 'A1 G9 note: no admin on this lane to test with — admin path not exercised';
  ELSE
    _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_set_account_state(%L, 'under_review', '')$q$, _m3));
    IF _r NOT LIKE 'refused 22023%' THEN _fail := _fail || ('G9 empty reason accepted: ' || _r); END IF;
    _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_set_account_state(%L, 'under_review', 'A1 PROBE check')$q$, _m3));
    IF _r <> 'ok under_review' THEN _fail := _fail || ('G9 admin could not set state: ' || _r); END IF;
    IF NOT EXISTS (SELECT 1 FROM public.account_state_log WHERE user_id = _m3 AND to_state = 'under_review' AND actor_id = _admin) THEN
      _fail := _fail || 'G9 no log row'::text;
    END IF;
    _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_set_account_state(%L, 'active', 'A1 PROBE restore')$q$, _m3));
    IF _r <> 'ok active' OR EXISTS (SELECT 1 FROM public.account_states WHERE user_id = _m3) THEN
      _fail := _fail || ('G9 restore to active failed: ' || _r);
    END IF;
  END IF;
  BEGIN
    UPDATE public.account_state_log SET reason = 'edited' WHERE true;
    IF FOUND THEN _fail := _fail || 'G9 log row was edited'::text; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'A1 FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'A1 FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'A1 PASS (lane %) — every member-writable table guarded or passive; under review = refused (direct and through server functions), passive still works; active + service unaffected; suspended folded in; state admin-only, reasoned, logged, append-only',
    current_setting('p32.lane', true);
END
$p$;

ROLLBACK;

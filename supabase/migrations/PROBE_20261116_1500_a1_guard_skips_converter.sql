-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261116_1500 — the account guard lets the converter / media worker
-- through and still stops real members. One transaction, ROLLBACK (the switch
-- flip, the test blur row, the test follow and the test flag are thrown away).
-- Before 20261116_1500: FAIL (F1/F3 — the converter is refused). After: PASS.
--   F1  account_can_act(converter) = true
--   F2  a real member flagged suspended + banned → account_can_act = false
--   F3  guard ON: the converter records a blur code (photo_blur_record) — the
--       exact call that failed on live (run 43860062887)
--   F4  guard ON: a real suspended member's write is still ACCOUNT_UNDER_REVIEW
--   F5  guard ON: a real member under review is still refused
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
  _r text; _conv uuid; _m1 uuid; _m2 uuid;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'A1-FIX lane %', current_setting('p32.lane', true);
  SELECT user_id INTO _conv FROM public.video_converter_accounts ORDER BY created_at LIMIT 1;
  SELECT p.id INTO _m1 FROM public.profiles p
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false)
     AND NOT EXISTS (SELECT 1 FROM public.video_converter_accounts c WHERE c.user_id = p.id)
     AND NOT EXISTS (SELECT 1 FROM public.account_states s WHERE s.user_id = p.id)
     AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text <> 'user')
   ORDER BY p.created_at DESC LIMIT 1;
  SELECT p.id INTO _m2 FROM public.profiles p
   WHERE p.id <> _m1 AND NOT p.is_suspended AND NOT coalesce(p.is_banned, false)
     AND NOT EXISTS (SELECT 1 FROM public.video_converter_accounts c WHERE c.user_id = p.id)
     AND NOT EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = _m1 AND f.following_id = p.id)
   ORDER BY p.created_at DESC LIMIT 1;
  IF _m1 IS NULL OR _m2 IS NULL THEN RAISE EXCEPTION 'A1-FIX PROBE: not enough plain members on this lane'; END IF;

  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';

  IF _conv IS NULL THEN
    RAISE NOTICE 'A1-FIX note: no converter account on this lane — F1/F3 not exercised';
  ELSE
    -- F1
    IF NOT public.account_can_act(_conv) THEN _fail := _fail || 'F1 converter cannot act'::text; END IF;
    -- F3
    _r := pg_temp.as_user(_conv, $q$SELECT public.photo_blur_record('[{"url":"probe://a1-fix-20261116","hash":"A1FIXPROBE0"}]'::jsonb)$q$);
    IF _r <> 'ok 1' THEN _fail := _fail || ('F3 converter blur record: ' || _r); END IF;
  END IF;

  -- F2 + F4
  UPDATE public.profiles SET is_suspended = true, is_banned = true WHERE id = _m1;
  IF public.account_can_act(_m1) THEN _fail := _fail || 'F2 banned real member can act'::text; END IF;
  _r := pg_temp.as_user(_m1, format('INSERT INTO public.follows (follower_id, following_id) VALUES (%L, %L)', _m1, _m2));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('F4 banned real member not refused: ' || _r); END IF;
  UPDATE public.profiles SET is_suspended = false, is_banned = false WHERE id = _m1;

  -- F5
  INSERT INTO public.account_states (user_id, state, reason) VALUES (_m1, 'under_review', 'A1-FIX PROBE')
  ON CONFLICT (user_id) DO UPDATE SET state = 'under_review';
  _r := pg_temp.as_user(_m1, format('INSERT INTO public.follows (follower_id, following_id) VALUES (%L, %L)', _m1, _m2));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('F5 member under review not refused: ' || _r); END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'A1-FIX FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'A1-FIX FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'A1-FIX PASS (lane %) — converter / media worker writes with the guard ON; banned, suspended and under-review members still refused',
    current_setting('p32.lane', true);
END
$p$;

ROLLBACK;

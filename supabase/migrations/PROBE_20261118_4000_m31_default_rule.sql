-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_4000 — M31 default rule + apply to everyone. One transaction, ROLLBACK.
-- Before 20261118_4000: FAIL (message_default_rules missing). After: M31 PASS.
--   P1  the default row exists; no member-facing messaging check still reads message_member_rules for the acting member;
--       the fixed 50 / 500 daily-limit line is gone (the send check reads the default limits)
--   P2  a member with no rule of their own follows the default AT ONCE (groups off in the default → groups refused)
--   P3  a member with their own rule keeps it on a plain save; "apply to everyone" replaces it; a running pause is kept
--   P4  members cannot read or change the default; members cannot call message_effective_rule; a reason is required
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

CREATE FUNCTION pg_temp.set_user(_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _ids uuid[]; _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; _r jsonb; _msg text; _n int; _left text;
  _read constant text := '(?<!DELETE )FROM public\.message_member_rules( [a-z_]+)? WHERE (?:[a-z_]+\.)?user_id = (_[a-z_]+|\(SELECT auth\.uid\(\)\))';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'M31 lane %', current_setting('p32.lane', true);
  IF to_regclass('public.message_default_rules') IS NULL THEN
    RAISE EXCEPTION 'M31 FAIL: message_default_rules missing — expected before 20261118_4000';
  END IF;

  -- P1
  IF (SELECT count(*) FROM public.message_default_rules) <> 1 THEN _fail := _fail || 'P1 the default rule is not exactly one row'; END IF;
  SELECT string_agg(p.proname, ', ') INTO _left FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.proname <> 'message_effective_rule'
     AND p.proname NOT LIKE 'message\_admin\_%' AND p.proname NOT LIKE 'admin\_%' AND p.prosrc ~ _read;
  IF _left IS NOT NULL THEN _fail := _fail || ('P1 still reading the raw member rule: ' || _left); END IF;
  SELECT string_agg(p.proname, ', ') INTO _left FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND position('THEN 50 ELSE 500 END' IN p.prosrc) > 0;
  IF _left IS NOT NULL THEN _fail := _fail || ('P1 fixed 50 / 500 limit still in: ' || _left); END IF;
  SELECT count(*) INTO _n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND position('message_default_rules dr' IN p.prosrc) > 0;
  IF _n = 0 THEN _fail := _fail || 'P1 no send check reads the default daily limits'; END IF;

  -- set-up: three members with chat, one admin
  SELECT array_agg(s.id) INTO _ids FROM (SELECT p.id FROM public.profiles p JOIN auth.users u ON u.id = p.id
   WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false) AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'admin') ORDER BY p.created_at LIMIT 3) s;
  IF coalesce(array_length(_ids, 1), 0) < 3 THEN RAISE EXCEPTION 'M31 FAIL: need three members to test with'; END IF;
  _m1 := _ids[1]; _m2 := _ids[2]; _m3 := _ids[3];
  SELECT rr.user_id INTO _admin FROM public.user_roles rr JOIN auth.users u ON u.id = rr.user_id WHERE rr.role::text = 'admin' ORDER BY rr.user_id LIMIT 1;
  IF _admin IS NULL THEN RAISE EXCEPTION 'M31 FAIL: need one admin to test with'; END IF;
  UPDATE public.system_flags SET value = true WHERE key = 'account_state_guard';
  UPDATE public.message_control SET mode = 'allowed_selected', groups_enabled = true WHERE id;
  DELETE FROM public.message_control_members WHERE user_id IS NOT NULL;
  INSERT INTO public.message_control_members (user_id) VALUES (_m1), (_m2), (_m3);
  DELETE FROM public.message_member_rules WHERE user_id = ANY (_ids);

  -- P2
  PERFORM pg_temp.set_user(_m1);
  IF NOT public.message_groups_allowed_me() THEN _fail := _fail || 'P2 groups refused before any default change'; END IF;
  PERFORM pg_temp.set_user(_admin);
  _r := public.admin_message_default_get();
  IF (_r ->> 'daily_limit')::int <> 500 OR (_r ->> 'new_daily_limit')::int <> 50 THEN _fail := _fail || ('P2 seeded limits wrong: ' || _r::text); END IF;
  -- m2 gets an own rule (groups on), m3 an own rule with a running pause
  PERFORM public.message_admin_set_member_rule(_m2, true, true, true, false, 99, NULL, 'probe M31');
  PERFORM public.message_admin_set_member_rule(_m3, true, true, true, false, NULL, now() + interval '3 days', 'probe M31');
  PERFORM public.message_admin_set_default(true, false, false, false, 300, 30, false, 'probe M31 chat only');
  PERFORM pg_temp.set_user(_m1);
  IF public.message_groups_allowed_me() THEN _fail := _fail || 'P2 a member without own rule still has groups after the default turned groups off'; END IF;
  IF (SELECT photos_ok FROM public.message_effective_rule(_m1)) THEN _fail := _fail || 'P2 default photos off not effective'; END IF;

  -- P3
  PERFORM pg_temp.set_user(_m2);
  IF NOT public.message_groups_allowed_me() THEN _fail := _fail || 'P3 a member''s own rule was overridden by a plain save'; END IF;
  PERFORM pg_temp.set_user(_admin);
  _r := public.message_admin_set_default(true, false, false, false, 300, 30, true, 'probe M31 apply');
  IF coalesce((_r ->> 'replaced')::int, 0) < 2 THEN _fail := _fail || ('P3 apply replaced too few own rules: ' || _r::text); END IF;
  PERFORM pg_temp.set_user(_m2);
  IF public.message_groups_allowed_me() THEN _fail := _fail || 'P3 apply to everyone did not reach a member with an own rule'; END IF;
  IF EXISTS (SELECT 1 FROM public.message_member_rules WHERE user_id = _m2) THEN _fail := _fail || 'P3 the replaced own rule was not removed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.message_member_rules WHERE user_id = _m3 AND blocked_until > now() AND NOT photos_ok) THEN
    _fail := _fail || 'P3 the paused member lost the pause or did not get the default';
  END IF;
  -- photos back on + apply → everyone has photos at once
  PERFORM pg_temp.set_user(_admin);
  PERFORM public.message_admin_set_default(true, true, true, false, 500, 50, true, 'probe M31 photos back');
  IF NOT (SELECT photos_ok FROM public.message_effective_rule(_m1)) OR NOT (SELECT photos_ok FROM public.message_effective_rule(_m3)) THEN
    _fail := _fail || 'P3 photos did not come back for everyone';
  END IF;

  -- P4
  PERFORM pg_temp.set_user(_m1);
  BEGIN
    PERFORM public.message_admin_set_default(true, true, true, false, 500, 50, true, 'member try');
    _fail := _fail || 'P4 a member changed the default';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.admin_message_default_get();
    _fail := _fail || 'P4 a member read the default';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF has_function_privilege('authenticated', 'public.message_effective_rule(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.message_effective_rule(uuid)', 'EXECUTE') THEN
    _fail := _fail || 'P4 members or visitors can call message_effective_rule';
  END IF;
  PERFORM pg_temp.set_user(_admin);
  BEGIN
    PERFORM public.message_admin_set_default(true, true, true, false, 500, 50, false, '  ');
    _fail := _fail || 'P4 saved without a reason';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  IF array_length(_fail, 1) > 0 THEN
    RAISE EXCEPTION 'M31 FAIL (% problem(s)): %', array_length(_fail, 1), array_to_string(_fail, ' | ');
  END IF;
  RAISE NOTICE 'M31 PASS — default rule works at once for members without own rules; apply to everyone replaces own rules and keeps pauses; admin only';
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════
-- PROBE · 20261126_6500 floating_footer switch. WRITES NOTHING (one transaction, ROLLBACK). FAILS before apply.
-- PASS = the row exists, its key is in feature_access_feature_check, and an ordinary member's
-- features_allowed_me() answers floating_footer = false while the switch is Off, true when All members.
-- Prints no member data.
-- ═══════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE _u uuid; _mode text; _off boolean; _on boolean;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  SELECT mode INTO _mode FROM public.feature_access WHERE feature = 'floating_footer';
  IF _mode IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL: switch floating_footer missing (6500 not applied)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'public.feature_access'::regclass
                  AND c.conname = 'feature_access_feature_check' AND pg_get_constraintdef(c.oid) LIKE '%''floating_footer''%') THEN
    RAISE EXCEPTION 'PROBE FAIL: floating_footer is not in feature_access_feature_check';
  END IF;

  SELECT u.id INTO _u FROM auth.users u
   WHERE NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = u.id) LIMIT 1;
  IF _u IS NULL THEN
    RAISE NOTICE 'PROBE PASS (structure only: no ordinary member on this lane)';
    RETURN;
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _u, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _u::text, true);

  UPDATE public.feature_access SET mode = 'off' WHERE feature = 'floating_footer';
  _off := coalesce((public.features_allowed_me()::jsonb ->> 'floating_footer')::boolean, false);
  UPDATE public.feature_access SET mode = 'everyone' WHERE feature = 'floating_footer';
  _on := coalesce((public.features_allowed_me()::jsonb ->> 'floating_footer')::boolean, false);
  IF _off OR NOT _on THEN
    RAISE EXCEPTION 'PROBE FAIL: Off answered %, All members answered %', _off, _on;
  END IF;
  RAISE NOTICE 'PROBE PASS: mode on this lane = %, Off -> false, All members -> true', _mode;
END
$p$;

ROLLBACK;

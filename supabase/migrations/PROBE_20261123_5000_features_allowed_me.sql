-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261123_5000 features_allowed_me. WRITES NOTHING (ROLLBACK). FAILS before apply.
--   F1  structure + grants (authenticated only, never anon)
--   F2  for two real members, every switch in the batched answer equals feature_allowed_me(switch)
-- Prints counts only.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';

DO $p$
DECLARE
  _m uuid;
  _all jsonb;
  _f text;
  _one boolean;
  _checked integer := 0;
  _switches text[];
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  IF to_regprocedure('public.features_allowed_me()') IS NULL THEN RAISE EXCEPTION 'PROBE FAIL F1: 5000 not applied'; END IF;
  IF has_function_privilege('anon', 'public.features_allowed_me()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.features_allowed_me()', 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL F1: grants';
  END IF;
  -- The switch list is read HERE, as the PROBE's own role: members cannot read feature_access
  -- (that is the point of the definer functions). Under the member role only the two functions run.
  SELECT array_agg(feature ORDER BY feature) INTO _switches FROM public.feature_access;
  FOR _m IN
    (SELECT fam.user_id FROM public.feature_access_members fam LIMIT 1)
    UNION ALL
    (SELECT p.id FROM public.profiles p ORDER BY p.created_at LIMIT 1)
  LOOP
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _m::text, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
      _all := public.features_allowed_me();
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'PROBE FAIL F2: features_allowed_me() refused for a member: %', SQLERRM;
    END;
    IF (SELECT count(*) FROM jsonb_object_keys(_all)) <> coalesce(array_length(_switches, 1), 0) THEN
      RESET ROLE;
      RAISE EXCEPTION 'PROBE FAIL F2: batched answer has % switches, feature_access has %',
        (SELECT count(*) FROM jsonb_object_keys(_all)), coalesce(array_length(_switches, 1), 0);
    END IF;
    FOREACH _f IN ARRAY _switches LOOP
      _one := public.feature_allowed_me(_f);
      IF (_all ->> _f)::boolean IS DISTINCT FROM _one THEN
        RESET ROLE;
        RAISE EXCEPTION 'PROBE FAIL F2: switch % differs (batched %, single %)', _f, _all ->> _f, _one;
      END IF;
      _checked := _checked + 1;
    END LOOP;
    RESET ROLE;
  END LOOP;
  RAISE NOTICE 'N3-5000 PASS (lane %): F1–F2 hold; % switch answers compared', current_setting('p32.lane'), _checked;
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261116_1400 admin users v4. READ ONLY, ROLLBACK.
-- COUNTS ONLY — no member id, name or e-mail is printed.
--
-- PASS = the three functions exist as 1400 creates them: the two admin
-- functions SECURITY DEFINER, search_path '', EXECUTE authenticated only, the
-- admin gate in the body; member_status_of callable by no client role and in
-- the account_can_act order. Before the apply it FAILS (expected).
--
-- Always reports first the numbers each status tab will show with no filter,
-- computed straight from the tables with the same rule (the PROBE has no
-- admin session, so it does not call the admin functions).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE
  f oid; n text; r record;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  WITH st AS (
    SELECT CASE
             WHEN coalesce(p.is_banned, false)    THEN 'banned'
             WHEN coalesce(p.is_suspended, false) THEN 'suspended'
             WHEN s.state = 'deletion_requested'  THEN 'deletion_requested'
             WHEN s.state = 'under_review'        THEN 'under_review'
             ELSE 'active' END AS status
      FROM public.profiles p
      LEFT JOIN public.account_states s ON s.user_id = p.id
  )
  SELECT count(*) AS a,
         count(*) FILTER (WHERE status = 'active') AS act,
         count(*) FILTER (WHERE status = 'suspended') AS sus,
         count(*) FILTER (WHERE status = 'banned') AS ban,
         count(*) FILTER (WHERE status = 'under_review') AS rev,
         count(*) FILTER (WHERE status = 'deletion_requested') AS del
    INTO r FROM st;
  RAISE NOTICE 'TABS (lane %): All=% · Active=% · Suspended=% · Banned=% · Under review=% · Asked to delete=%',
    current_setting('p32.lane'), r.a, r.act, r.sus, r.ban, r.rev, r.del;

  IF to_regprocedure('public.admin_search_users_v3(text, text, text, text, text, integer, integer)') IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL: admin_search_users_v3 missing (the previous list the page falls back to)';
  END IF;

  FOREACH n IN ARRAY ARRAY[
    'public.admin_search_users_v4(text, text, text, text, text, text, text, integer, integer)',
    'public.admin_user_facets(text, text, text, text, text, text)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL THEN
      RAISE EXCEPTION 'PROBE FAIL: % missing (1400 not applied)', n;
    END IF;
    IF NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=""'] FROM pg_proc WHERE oid = f) THEN
      RAISE EXCEPTION 'PROBE FAIL: % is not SECURITY DEFINER with search_path=""', n;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) x WHERE p.oid = f AND x.grantee = 0) THEN
      RAISE EXCEPTION 'PROBE FAIL: % EXECUTE is not authenticated-only', n;
    END IF;
    IF position('has_role(auth.uid(), ''admin'')' IN pg_get_functiondef(f)) = 0
       OR position('Not authorized' IN pg_get_functiondef(f)) = 0 THEN
      RAISE EXCEPTION 'PROBE FAIL: % has no admin gate', n;
    END IF;
  END LOOP;

  f := to_regprocedure('public.member_status_of(boolean, boolean, text)');
  IF f IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL: member_status_of missing (1400 not applied)';
  END IF;
  IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROBE FAIL: member_status_of is callable by a client role';
  END IF;
  IF public.member_status_of(true, true, 'under_review') <> 'banned'
     OR public.member_status_of(false, true, 'deletion_requested') <> 'suspended'
     OR public.member_status_of(false, false, 'under_review') <> 'under_review'
     OR public.member_status_of(false, false, NULL) <> 'active' THEN
    RAISE EXCEPTION 'PROBE FAIL: member_status_of order is wrong';
  END IF;

  RAISE NOTICE 'PROBE PASS: 20261116_1400 present as intended';
END
$p$;

ROLLBACK;

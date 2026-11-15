-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1300 — A0: what must obey the account state (READ ONLY).
-- Plan Part 3 (account review and deletion). Counts and names only — never a
-- member id, e-mail or row content.
--   A0-1  members flagged suspended / banned today (counts)
--   A0-2  every public table a signed-in member can write by RLS (INSERT /
--         UPDATE / DELETE / ALL policies for authenticated or public), and how
--         many of those policies look at is_suspended / is_banned at all
--   A0-3  SECURITY DEFINER functions a signed-in member can run that write
--         (INSERT / UPDATE / DELETE in the body), and how many check the flags
--   A0-4  table grants: INSERT/UPDATE/DELETE held by authenticated (count)
--   A0-5  auth-side deletion helpers present (names)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE r record; _n int; _m int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'A0 lane %', current_setting('p32.lane', true);

  -- A0-1
  EXECUTE 'SELECT count(*) FILTER (WHERE is_suspended), count(*) FILTER (WHERE is_banned) FROM public.profiles' INTO _n, _m;
  RAISE NOTICE 'A0-1 profiles suspended=% banned=% total=%', _n, _m, (SELECT count(*) FROM public.profiles);

  -- A0-2
  SELECT count(DISTINCT tablename), count(*)
    INTO _n, _m
    FROM pg_policies
   WHERE schemaname = 'public' AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
     AND (roles && ARRAY['authenticated', 'public']::name[]);
  RAISE NOTICE 'A0-2 member-writable tables=% write policies=%', _n, _m;
  SELECT count(*) INTO _n FROM pg_policies
   WHERE schemaname = 'public' AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
     AND (roles && ARRAY['authenticated', 'public']::name[])
     AND coalesce(qual, '') || coalesce(with_check, '') ~* '(is_suspended|is_banned|banned_until)';
  RAISE NOTICE 'A0-2 write policies that check suspended/banned=%', _n;
  FOR r IN SELECT tablename, string_agg(DISTINCT cmd, ',' ORDER BY cmd) AS cmds, count(*) AS n
             FROM pg_policies
            WHERE schemaname = 'public' AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
              AND (roles && ARRAY['authenticated', 'public']::name[])
            GROUP BY 1 ORDER BY 1 LOOP
    RAISE NOTICE 'A0-2 table % [%] policies=%', r.tablename, r.cmds, r.n;
  END LOOP;

  -- A0-3
  SELECT count(*), count(*) FILTER (WHERE p.prosrc ~* '(is_suspended|is_banned|banned_until)')
    INTO _n, _m
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.prosecdef
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
     AND p.prosrc ~* '\m(insert\s+into|update\s+public\.|update\s+[a-z_]+\s+set|delete\s+from)';
  RAISE NOTICE 'A0-3 member-runnable SECURITY DEFINER writers=% of which check suspended/banned=%', _n, _m;

  -- A0-4
  SELECT count(DISTINCT table_name) INTO _n FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND grantee = 'authenticated' AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE');
  RAISE NOTICE 'A0-4 tables where authenticated holds INSERT/UPDATE/DELETE grants=%', _n;

  -- A0-5
  FOR r IN SELECT p.proname FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
            WHERE ns.nspname = 'public' AND p.proname ~* '(delete_user|delete_my|delete_account|hard_delete|purge_user)'
            ORDER BY 1 LOOP
    RAISE NOTICE 'A0-5 delete helper %', r.proname;
  END LOOP;
  RAISE NOTICE 'A0 DONE';
END
$p$;

ROLLBACK;

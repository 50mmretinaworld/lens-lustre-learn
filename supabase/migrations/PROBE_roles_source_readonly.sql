-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBE · where do members' roles come from? READ ONLY, ROLLBACK. Owner bug list 28 Nov, item 18: "photographer /
-- student still auto-assigned by users — every role and badge is given by Admin only".
--   A  every INSERT / ALL policy on user_roles and role_applications (who may add a row)
--   B  per role: members holding it, how many were added per month (created_at), and the newest add
--   C  roles added since 26 Nov 2026 (after A0 / SQL 6600) — counts per role per day
--   D  triggers on auth.users / profiles / user_roles that write roles
-- Counts, dates and object names only; no member.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE r record; line text := '';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  FOR r IN
    SELECT tablename, policyname, cmd, roles::text AS who, left(regexp_replace(coalesce(with_check, qual, ''), '\s+', ' ', 'g'), 160) AS rule
      FROM pg_policies
     WHERE schemaname = 'public' AND tablename IN ('user_roles', 'role_applications') AND cmd IN ('INSERT', 'ALL')
     ORDER BY 1, 2
  LOOP
    line := line || format(E'\n  %s · %s · %s · %s · %s', r.tablename, r.policyname, r.cmd, r.who, r.rule);
  END LOOP;
  RAISE NOTICE 'A · WHO MAY ADD A ROLE ROW:%', coalesce(nullif(line, ''), E'\n  (no insert policy)');

  line := '';
  FOR r IN
    SELECT role::text AS role, count(*) AS holders, max(created_at) AS newest,
           string_agg(m || '=' || n, ' ' ORDER BY m) AS per_month
      FROM (SELECT role, created_at, to_char(created_at AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM') AS m,
                   count(*) OVER (PARTITION BY role, to_char(created_at AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM')) AS n
              FROM public.user_roles) x
     GROUP BY role ORDER BY role
  LOOP
    line := line || format(E'\n  %-24s holders=%-5s newest=%s', r.role, r.holders, to_char(r.newest AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'));
  END LOOP;
  RAISE NOTICE 'B · ROLES HELD:%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT role::text AS role, (created_at AT TIME ZONE 'Asia/Kolkata')::date AS d, count(*) AS n
      FROM public.user_roles
     WHERE created_at >= timestamptz '2026-11-26 00:00+05:30' AND role::text <> 'user'
     GROUP BY 1, 2 ORDER BY 2, 1
  LOOP
    line := line || format(E'\n  %s %-24s added=%s', r.d, r.role, r.n);
  END LOOP;
  RAISE NOTICE 'C · ROLES ADDED SINCE 26 NOV (not "user"):%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT c.relnamespace::regnamespace::text || '.' || c.relname AS tbl, t.tgname, p.proname
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE NOT t.tgisinternal AND position('user_roles' IN pg_get_functiondef(p.oid)) > 0
       AND position('insert' IN lower(pg_get_functiondef(p.oid))) > 0
     ORDER BY 1, 2
  LOOP
    line := line || format(E'\n  %s · trigger %s · function %s', r.tbl, r.tgname, r.proname);
  END LOOP;
  RAISE NOTICE 'D · TRIGGERS WHOSE FUNCTION WRITES user_roles:%', coalesce(nullif(line, ''), E'\n  (none)');
END
$p$;

ROLLBACK;

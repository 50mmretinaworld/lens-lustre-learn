-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1301 — A0b (READ ONLY): public tables that member-runnable
-- SECURITY DEFINER functions write (INSERT INTO / UPDATE / DELETE FROM in the
-- body) but that have NO member write policy — so a guard attached only by
-- policy would miss them. Names and counts only.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE r record;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'A0b lane %', current_setting('p32.lane', true);
  FOR r IN
    WITH fn AS (
      SELECT p.proname, p.prosrc FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
       WHERE ns.nspname = 'public' AND p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    ), hit AS (
      SELECT fn.proname, lower(m[2]) AS tbl
        FROM fn, regexp_matches(fn.prosrc, '(insert\s+into|update|delete\s+from)\s+(?:public\.)?"?([a-z_][a-z0-9_]*)"?', 'gi') m
    )
    SELECT h.tbl, count(DISTINCT h.proname) AS fns, string_agg(DISTINCT h.proname, ',') AS names
      FROM hit h
      JOIN pg_class c ON c.relname = h.tbl AND c.relkind IN ('r', 'p')
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE NOT EXISTS (SELECT 1 FROM pg_policies pp WHERE pp.schemaname = 'public' AND pp.tablename = h.tbl
                         AND pp.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
                         AND pp.roles && ARRAY['authenticated', 'public']::name[])
     GROUP BY 1 ORDER BY 1
  LOOP
    RAISE NOTICE 'A0b table % written_by=% | %', r.tbl, r.fns, left(r.names, 160);
  END LOOP;
  RAISE NOTICE 'A0b DONE';
END
$p$;

ROLLBACK;

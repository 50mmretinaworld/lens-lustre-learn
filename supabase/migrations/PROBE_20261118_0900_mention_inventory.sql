-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_0900 — member tags in stored text (READ ONLY). Counts only:
-- never a name, an id or any text leaves the database.
--
-- Owner 18 Nov 2026: a story comment showed "@[Name](id)". A tag is stored as
-- `@[Name](member-id)` — the NAME is a copy made when the tag was typed. This
-- measures, per table that can hold one:
--   rows   rows carrying at least one member tag
--   tags   member tags in total            groups  @all / @followers tags
--   stale  tags whose copied name is no longer the member's profile name
--   gone   tags pointing at a member who no longer exists
-- The root fix reads every tag's name from the profile (one source), so `stale`
-- is the number of tags that show an OLD name on screen today.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '120s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  src  record;
  r    record;
  tot_tags bigint := 0; tot_stale bigint := 0; tot_gone bigint := 0;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'MT lane %', current_setting('p32.lane', true);

  FOR src IN SELECT * FROM (VALUES
      ('posts', 'content'), ('post_comments', 'content'), ('image_comments', 'content'),
      ('comments', 'content'), ('story_comments', 'content'), ('stories', 'caption')
    ) AS v(tbl, col)
  LOOP
    IF to_regclass('public.' || src.tbl) IS NULL THEN
      RAISE NOTICE 'MT % — table not on this lane', src.tbl;
      CONTINUE;
    END IF;
    EXECUTE format($q$
      WITH t AS (
        SELECT x.id AS row_id, m[1] AS name, m[2] AS ref
          FROM public.%I x, regexp_matches(x.%I, '@\[([^\]]+)\]\(([^)]+)\)', 'g') AS m
         WHERE x.%I LIKE '%%@[%%'
      )
      SELECT count(DISTINCT row_id) FILTER (WHERE ref NOT IN ('all', 'followers'))        AS rows,
             count(*) FILTER (WHERE ref NOT IN ('all', 'followers'))                      AS tags,
             count(*) FILTER (WHERE ref IN ('all', 'followers'))                          AS groups,
             count(*) FILTER (WHERE ref NOT IN ('all', 'followers') AND p.id IS NOT NULL
                                AND btrim(p.full_name) IS DISTINCT FROM btrim(t.name))    AS stale,
             count(*) FILTER (WHERE ref NOT IN ('all', 'followers') AND p.id IS NULL)     AS gone
        FROM t
        LEFT JOIN public.profiles p
          ON p.id = CASE WHEN ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN ref::uuid END
    $q$, src.tbl, src.col, src.col) INTO r;
    RAISE NOTICE 'MT %.% rows=% tags=% groups=% stale=% gone=%', src.tbl, src.col, r.rows, r.tags, r.groups, r.stale, r.gone;
    tot_tags := tot_tags + r.tags; tot_stale := tot_stale + r.stale; tot_gone := tot_gone + r.gone;
  END LOOP;
  RAISE NOTICE 'MT TOTAL member tags=% showing an old name=% pointing at no member=%', tot_tags, tot_stale, tot_gone;
  RAISE NOTICE 'MT DONE';
END
$p$;

ROLLBACK;

-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBE · badge definitions and how many members hold each badge. READ ONLY, ROLLBACK.
-- Owner bug list 28 Nov, item 14: on Android 1.2.63, on a slow connection, a name showed "✓ Elite Member" in
-- words before the tick icon. The words come from a badge_definitions row drawn as a pill; this lists every
-- definition (key, label, icon, label shown or not) and the number of members holding each badge type, including
-- badge types that have NO definition. Keys, labels and counts only; no member.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE r record; line text := '';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  FOR r IN
    SELECT coalesce(d.type_key, b.badge_type) AS k, d.label, d.icon, d.show_label,
           (SELECT count(*) FROM public.user_badges x WHERE x.badge_type = coalesce(d.type_key, b.badge_type)) AS holders,
           d.type_key IS NULL AS no_definition
      FROM public.badge_definitions d
      FULL JOIN (SELECT DISTINCT badge_type FROM public.user_badges) b ON b.badge_type = d.type_key
     ORDER BY 1
  LOOP
    line := line || format(E'\n  %-22s label=%-24s icon=%-3s show_label=%-5s holders=%s%s',
      r.k, coalesce(r.label, '-'), coalesce(r.icon, '-'), coalesce(r.show_label::text, '-'), r.holders,
      CASE WHEN r.no_definition THEN '  (NO DEFINITION)' ELSE '' END);
  END LOOP;
  RAISE NOTICE 'BADGES:%', coalesce(nullif(line, ''), E'\n  (none)');

  line := '';
  FOR r IN
    SELECT n.nspname || '.' || p.proname AS fn
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND position('elite_member' IN pg_get_functiondef(p.oid)) > 0
     ORDER BY 1
  LOOP
    line := line || E'\n  ' || r.fn;
  END LOOP;
  RAISE NOTICE 'FUNCTIONS THAT NAME elite_member:%', coalesce(nullif(line, ''), E'\n  (none)');
END
$p$;

ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_3900 · M30 — admin switches failed on the live site: "UPDATE requires a WHERE clause" (Owner 22 Nov 2026)
--
--  The live database refuses any UPDATE that has no WHERE (safe-update guard). Three admin functions update their one-row table
--  without one, so the Groups switch, the "Who can message" mode and the Welcome message could not be saved:
--     message_admin_set_mode · message_admin_set_groups · admin_message_welcome_set
--  Fix: the same statements with  WHERE id  (the table's single row; id is boolean true). Nothing else in the functions changes.
--
-- Rollback: supabase/rollback/20261118_3900_m30_switch_where_clause_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_3900_m30_switch_where_clause.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_admin_set_mode(text,text)') IS NULL
     OR to_regprocedure('public.message_admin_set_groups(boolean,text)') IS NULL
     OR to_regprocedure('public.admin_message_welcome_set(boolean,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'M30-PRE-001: one of the three switch functions is missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DO $patch$
DECLARE
  _sig text; _def text; _new text;
BEGIN
  FOREACH _sig IN ARRAY ARRAY[
    'public.message_admin_set_mode(text,text)',
    'public.message_admin_set_groups(boolean,text)',
    'public.admin_message_welcome_set(boolean,text,boolean)'
  ] LOOP
    _def := pg_get_functiondef(_sig::regprocedure);
    IF (length(_def) - length(replace(_def, 'updated_at = now();', ''))) <> length('updated_at = now();') THEN
      RAISE EXCEPTION 'M30-PRE-002: % — expected exactly one "updated_at = now();" anchor', _sig;
    END IF;
    IF _def ~ 'updated_at = now\(\) WHERE id;' THEN
      RAISE EXCEPTION 'M30-PRE-003: % already has a WHERE — not re-applying', _sig;
    END IF;
    _new := replace(_def, 'updated_at = now();', 'updated_at = now() WHERE id;');
    EXECUTE _new;
  END LOOP;
END
$patch$;

COMMIT;

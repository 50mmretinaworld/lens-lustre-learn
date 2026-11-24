-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261124_5400 inbox list cap. Lanes: staging, production.
-- Puts the cap back to 100 in both functions (the same in-place text patch, reversed). The app keeps working: it
-- simply receives at most 100 chats again.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED — p32.lane reads %. Dispatch apply-migration.yml (it sets p32.lane from target).',
      coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $patch$
DECLARE
  _fn  text;
  _def text;
  _old constant text := 'least(greatest(coalesce(_limit, 30), 1), 500)';
  _new constant text := 'least(greatest(coalesce(_limit, 30), 1), 100)';
BEGIN
  FOREACH _fn IN ARRAY ARRAY['public.message_my_conversations(text,integer,timestamptz)',
                             'public.admin_view_inbox(uuid,text,integer,timestamptz)'] LOOP
    _def := pg_get_functiondef(to_regprocedure(_fn));
    IF position(_old IN _def) = 0 THEN
      RAISE EXCEPTION 'MSG-5400-ROLLBACK: % does not carry the 500 cap', _fn;
    END IF;
    EXECUTE replace(_def, _old, _new);
    RAISE NOTICE 'MSG-5400 ROLLBACK: % back to 100', _fn;
  END LOOP;
END
$patch$;

COMMIT;

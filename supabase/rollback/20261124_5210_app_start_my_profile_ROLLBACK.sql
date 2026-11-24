-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261124_5210 my_profile part. Lanes: staging, production.
-- Removes only the my_profile part from get_app_start (in-place text patch of the live definition: the part's block
-- is cut out exactly). The app then reads the member's own profile alone, as before 5210. Everything else from 5200
-- stays. Refused unless the block is found exactly once.
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
  _def   text := pg_get_functiondef('public.get_app_start(integer,text[])'::regprocedure);
  _start integer;
  _end   integer;
  _tail  text;
BEGIN
  _start := position('-- ⚑ useProfileData core' IN _def);
  IF _start = 0 THEN
    RAISE EXCEPTION 'N6-5210-ROLLBACK: the my_profile block is not in the live get_app_start';
  END IF;
  -- back to the start of that line (the block's own BEGIN sits on it)
  _start := _start - position(E'\n' IN reverse(substr(_def, 1, _start - 1))) + 1;
  _tail := substr(_def, _start);
  _end := position('EXCEPTION WHEN OTHERS THEN NULL; END;' IN _tail);
  IF _end = 0 THEN
    RAISE EXCEPTION 'N6-5210-ROLLBACK: the end of the my_profile block was not found';
  END IF;
  EXECUTE substr(_def, 1, _start - 1) || substr(_tail, _end + length('EXCEPTION WHEN OTHERS THEN NULL; END;'));
  IF position('my_profile' IN pg_get_functiondef('public.get_app_start(integer,text[])'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'N6-5210-ROLLBACK: my_profile still present';
  END IF;
  RAISE NOTICE 'N6-5210 ROLLBACK: my_profile part removed; the rest of get_app_start (5200) unchanged';
END
$patch$;

COMMIT;

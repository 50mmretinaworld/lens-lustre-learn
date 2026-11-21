-- ROLLBACK · 20261118_3100 · M19 photo retention
-- Stops the daily purge and removes the expired mark. Files already deleted from storage are NOT restorable
-- (that is the point of the 30 days); the rows would simply show a photo that no longer opens.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DO $patch$
DECLARE
  _f text; _def text;
BEGIN
  FOREACH _f IN ARRAY ARRAY['public.message_thread(uuid,bigint,integer)', 'public.admin_view_thread(uuid,uuid,bigint,integer)'] LOOP
    _def := pg_get_functiondef(_f::regprocedure);
    EXECUTE replace(_def, '''height'', a.height, ''expired'', (a.expired_at IS NOT NULL))', '''height'', a.height)');
  END LOOP;
  _def := pg_get_functiondef('public.message_maintenance(jsonb)'::regprocedure);
  EXECUTE replace(_def, E'\n  PERFORM public.job_enqueue(''message.photo_purge'', ''{}''::jsonb, ''photo-purge:'' || to_char(now() AT TIME ZONE ''UTC'', ''YYYY-MM-DD''));', '');
END
$patch$;

DELETE FROM public.jobs WHERE kind = 'message.photo_purge' AND status IN ('queued');
DELETE FROM public.job_kinds WHERE kind = 'message.photo_purge' AND NOT EXISTS (SELECT 1 FROM public.jobs j WHERE j.kind = 'message.photo_purge');
DROP FUNCTION IF EXISTS public.message_photos_due(integer);
DROP FUNCTION IF EXISTS public.message_photos_mark_expired(uuid[]);
DROP INDEX IF EXISTS public.message_attachments_due_idx;
ALTER TABLE public.message_attachments DROP COLUMN IF EXISTS expired_at;

COMMIT;

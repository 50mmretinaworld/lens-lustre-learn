-- ROLLBACK · 20261118_3200 · M22 read receipts + admin views
-- Read ticks ignore the setting again; the admin viewer stops writing views and the table is dropped (rows are lost).
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
  _def text;
BEGIN
  _def := pg_get_functiondef('public.message_tick(uuid,uuid,timestamptz)'::regprocedure);
  EXECUTE replace(_def, 'WHEN bool_and(coalesce(cm.last_read_at, ''-infinity''::timestamptz) >= _created)
         AND NOT bool_or(coalesce((SELECT p.privacy_settings ->> ''read_receipts'' FROM public.profiles p WHERE p.id = cm.user_id), ''on'') = ''off'') THEN ''read''',
                  'WHEN bool_and(coalesce(cm.last_read_at, ''-infinity''::timestamptz) >= _created) THEN ''read''');

  _def := pg_get_functiondef('public.admin_view_thread(uuid,uuid,bigint,integer)'::regprocedure);
  _def := replace(_def, 'IF _before_id IS NULL AND NOT EXISTS (SELECT 1 FROM public.message_admin_views v WHERE v.admin_id = _uid AND v.conversation_id = _conversation AND v.at > now() - interval ''10 minutes'') THEN
    INSERT INTO public.message_admin_views (admin_id, member_id, conversation_id) VALUES (_uid, _user, _conversation);
  END IF;
  RETURN coalesce((', 'RETURN coalesce((');
  EXECUTE regexp_replace(_def, 'LANGUAGE plpgsql\s+SECURITY DEFINER', 'LANGUAGE plpgsql STABLE SECURITY DEFINER');
END
$patch$;

DROP TABLE IF EXISTS public.message_admin_views;

COMMIT;

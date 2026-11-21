-- ROLLBACK · 20261118_3300 · M23 delete chat for me
-- Everything a member cleared comes back (no message was ever deleted).
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
  _def := pg_get_functiondef('public.message_thread(uuid,bigint,integer)'::regprocedure);
  EXECUTE replace(_def, 'AND (_before_id IS NULL OR m2.id < _before_id)
               AND m2.created_at > coalesce((SELECT cx.cleared_at FROM public.conversation_members cx WHERE cx.conversation_id = _conversation AND cx.user_id = _me), ''-infinity''::timestamptz)',
                  'AND (_before_id IS NULL OR m2.id < _before_id)');
  _def := pg_get_functiondef('public.message_my_conversations(text,integer,timestamptz)'::regprocedure);
  EXECUTE replace(_def, 'AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = ''sent'' OR m.sender_id = _me)
                       AND m.created_at > coalesce(cm.cleared_at, ''-infinity''::timestamptz))',
                  'AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = ''sent'' OR m.sender_id = _me))');
END
$patch$;

DROP FUNCTION IF EXISTS public.message_clear_chat(uuid);
ALTER TABLE public.conversation_members DROP COLUMN IF EXISTS cleared_at;

COMMIT;

-- ROLLBACK · 20261118_4200 · M32 official account
-- Drops the two triggers and their functions, puts moved chat rows back in their old folder and restores removed blocks
-- (both saved in message_m32_backup), then drops the backup table.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_m32_backup') IS NULL THEN
    RAISE EXCEPTION 'M32-RB-001: message_m32_backup missing — M32 is not applied';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TRIGGER IF EXISTS conversation_members_official_folder ON public.conversation_members;
DROP TRIGGER IF EXISTS user_blocks_official_guard ON public.user_blocks;
DROP FUNCTION IF EXISTS public.message_official_folder();
DROP FUNCTION IF EXISTS public.user_blocks_official_guard();

UPDATE public.conversation_members cm
   SET folder = b.old_folder
  FROM public.message_m32_backup b
 WHERE b.kind = 'folder' AND b.conversation_id = cm.conversation_id AND b.user_id = cm.user_id;

INSERT INTO public.user_blocks (blocker_id, blocked_id, created_at)
SELECT b.blocker_id, b.blocked_id, b.blocked_at FROM public.message_m32_backup b
 WHERE b.kind = 'block'
ON CONFLICT DO NOTHING;

DROP TABLE public.message_m32_backup;

COMMIT;

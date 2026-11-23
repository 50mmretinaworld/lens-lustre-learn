-- ROLLBACK · 20261118_4300 · M33 official account cannot be muted
-- Drops the two guards, puts back the mutes / cleared chats and the post mutes saved in message_m33_backup, drops the backup.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_m33_backup') IS NULL THEN
    RAISE EXCEPTION 'M33-RB-001: message_m33_backup missing — M33 is not applied';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP TRIGGER IF EXISTS conversation_members_official_chat_guard ON public.conversation_members;
DROP TRIGGER IF EXISTS feed_muted_authors_official_guard ON public.feed_muted_authors;
DROP FUNCTION IF EXISTS public.message_official_chat_guard();
DROP FUNCTION IF EXISTS public.feed_muted_authors_official_guard();

UPDATE public.conversation_members cm
   SET muted = b.old_muted, cleared_at = b.old_cleared_at
  FROM public.message_m33_backup b
 WHERE b.kind = 'chat' AND b.conversation_id = cm.conversation_id AND b.user_id = cm.user_id;

INSERT INTO public.feed_muted_authors (user_id, author_id, created_at)
SELECT b.user_id, b.author_id, b.muted_at FROM public.message_m33_backup b
 WHERE b.kind = 'author_mute'
ON CONFLICT DO NOTHING;

DROP FUNCTION IF EXISTS public.message_is_member_official_chat(uuid, uuid);
DROP TABLE public.message_m33_backup;

COMMIT;

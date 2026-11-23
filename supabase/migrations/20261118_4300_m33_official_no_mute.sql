-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_4300 · M33 — the official 50mm Retina World account cannot be muted, and its chat cannot be deleted (Owner 22 Nov 2026)
--
--  Owner: "any member can't block 50mm Retina msg or profile … in the msg box they won't get the option of block, mute etc."
--  SQL 4200 already refuses blocks and keeps the chat in Chats; prevent_unfollow_official already refuses unfollow.
--  This adds, for a MEMBER's row of a direct chat with an admin (= official) account:
--   1. trigger on conversation_members (BEFORE UPDATE OF muted, cleared_at): turning mute ON or "Delete chat for me" is
--      refused (42501 MSG-OFFICIAL). Turning mute off / clearing cleared_at stays allowed.
--   2. trigger on feed_muted_authors (BEFORE INSERT / UPDATE): muting an admin author's posts is refused (42501).
--   3. existing mutes / cleared chats with the official account are undone (saved in message_m33_backup for the rollback).
--  The official account's own row is not limited.
--
-- Rollback: supabase/rollback/20261118_4300_m33_official_no_mute_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_4300_m33_official_no_mute.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_m32_backup') IS NULL THEN
    RAISE EXCEPTION 'M33-PRE-001: 20261118_4200 (M32) is not applied';
  END IF;
  IF to_regclass('public.message_m33_backup') IS NOT NULL THEN
    RAISE EXCEPTION 'M33-PRE-002: message_m33_backup already exists — not re-applying';
  END IF;
  IF to_regclass('public.feed_muted_authors') IS NULL
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'conversation_members' AND column_name = 'cleared_at') THEN
    RAISE EXCEPTION 'M33-PRE-003: feed_muted_authors or conversation_members.cleared_at missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

CREATE TABLE public.message_m33_backup (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind             text NOT NULL CHECK (kind IN ('chat', 'author_mute')),
  conversation_id  uuid,
  user_id          uuid NOT NULL,
  old_muted        boolean,
  old_cleared_at   timestamptz,
  author_id        uuid,
  muted_at         timestamptz,
  saved_at         timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.message_m33_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_m33_backup FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_m33_backup TO service_role;

-- true when this row belongs to a member (not admin) in a DIRECT chat whose other member is an admin (official) account
CREATE FUNCTION public.message_is_member_official_chat(_conversation uuid, _user uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT NOT public.has_role(_user, 'admin'::public.app_role)
     AND EXISTS (SELECT 1 FROM public.conversation_members o
                   JOIN public.conversations c ON c.id = o.conversation_id
                  WHERE o.conversation_id = _conversation AND o.user_id <> _user
                    AND c.kind = 'direct' AND public.has_role(o.user_id, 'admin'::public.app_role));
$fn$;
REVOKE ALL ON FUNCTION public.message_is_member_official_chat(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_is_member_official_chat(uuid, uuid) TO service_role;

-- ── 3 first: undo existing mutes / cleared chats (before the guards exist) ──
INSERT INTO public.message_m33_backup (kind, conversation_id, user_id, old_muted, old_cleared_at)
SELECT 'chat', cm.conversation_id, cm.user_id, cm.muted, cm.cleared_at
  FROM public.conversation_members cm
 WHERE (cm.muted OR cm.cleared_at IS NOT NULL)
   AND public.message_is_member_official_chat(cm.conversation_id, cm.user_id);

UPDATE public.conversation_members cm
   SET muted = false, cleared_at = NULL
  FROM public.message_m33_backup b
 WHERE b.kind = 'chat' AND b.conversation_id = cm.conversation_id AND b.user_id = cm.user_id;

INSERT INTO public.message_m33_backup (kind, user_id, author_id, muted_at)
SELECT 'author_mute', f.user_id, f.author_id, f.created_at
  FROM public.feed_muted_authors f
 WHERE public.has_role(f.author_id, 'admin'::public.app_role);

DELETE FROM public.feed_muted_authors f
 USING public.message_m33_backup b
 WHERE b.kind = 'author_mute' AND b.user_id = f.user_id AND b.author_id = f.author_id;

-- ── 1. the chat with the official account cannot be muted or deleted ──────
CREATE FUNCTION public.message_official_chat_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF ((NEW.muted AND NOT coalesce(OLD.muted, false))
      OR (NEW.cleared_at IS NOT NULL AND NEW.cleared_at IS DISTINCT FROM OLD.cleared_at))
     AND public.message_is_member_official_chat(NEW.conversation_id, NEW.user_id) THEN
    RAISE EXCEPTION 'MSG-OFFICIAL: the chat with 50mm Retina World cannot be muted or deleted' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_official_chat_guard() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER conversation_members_official_chat_guard
  BEFORE UPDATE OF muted, cleared_at ON public.conversation_members
  FOR EACH ROW EXECUTE FUNCTION public.message_official_chat_guard();

-- ── 2. the official account's posts cannot be muted ───────────────────────
CREATE FUNCTION public.feed_muted_authors_official_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.has_role(NEW.author_id, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MUTE-OFFICIAL: 50mm Retina World cannot be muted' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.feed_muted_authors_official_guard() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER feed_muted_authors_official_guard
  BEFORE INSERT OR UPDATE ON public.feed_muted_authors
  FOR EACH ROW EXECUTE FUNCTION public.feed_muted_authors_official_guard();

DO $report$
BEGIN
  RAISE NOTICE 'M33 applied — official chats un-muted / restored: %, mutes of the official account removed: %',
    (SELECT count(*) FROM public.message_m33_backup WHERE kind = 'chat'),
    (SELECT count(*) FROM public.message_m33_backup WHERE kind = 'author_mute');
END
$report$;

COMMIT;

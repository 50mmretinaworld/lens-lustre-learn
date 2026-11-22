-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_4200 · M32 — the official 50mm Retina World account (Owner 22 Nov 2026)
--
--  Owner: "Every chat with 50mm Retina World lands in the main box (Chats) for everyone. Nobody can block 50mm Retina World
--  in any way."  The official account is the admin-role account (PROBE 4100 on production 22 Nov: profile 50mmretinaworld
--  admin=t, 1 admin role holder, 0 chats with it in Requests, 0 blocks naming it).
--
--  1. Trigger on conversation_members (BEFORE INSERT / UPDATE OF folder): a row of a DIRECT chat with an admin account, and
--     every row OF an admin account, is always 'inbox'. One rule at the table, so every path obeys it — text send, photo
--     send, reply, broadcast, accept / decline — without patching each send function.
--  2. Existing rows of such chats in 'requests' / 'declined' move to 'inbox' (both sides). Moved rows are kept in
--     message_m32_backup for the rollback.
--  3. Trigger on user_blocks (BEFORE INSERT / UPDATE): blocking an admin account is refused (42501 BLOCK-OFFICIAL).
--     Existing blocks of an admin account are removed (kept in message_m32_backup).
--  The admin account itself can still block members.
--
-- Rollback: supabase/rollback/20261118_4200_m32_official_account_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_4200_m32_official_account.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_m32_backup') IS NOT NULL THEN
    RAISE EXCEPTION 'M32-PRE-001: message_m32_backup already exists — not re-applying';
  END IF;
  IF to_regclass('public.conversation_members') IS NULL OR to_regclass('public.user_blocks') IS NULL THEN
    RAISE EXCEPTION 'M32-PRE-002: conversation_members or user_blocks missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

CREATE TABLE public.message_m32_backup (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind             text NOT NULL CHECK (kind IN ('folder', 'block')),
  conversation_id  uuid,
  user_id          uuid,
  old_folder       text,
  blocker_id       uuid,
  blocked_id       uuid,
  blocked_at       timestamptz,
  saved_at         timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.message_m32_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_m32_backup FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_m32_backup TO service_role;

-- ── 1. chats with the official account always land in Chats ────────────────
CREATE FUNCTION public.message_official_folder()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.folder IS DISTINCT FROM 'inbox' AND (
       public.has_role(NEW.user_id, 'admin'::public.app_role)
       OR EXISTS (SELECT 1 FROM public.conversation_members o
                    JOIN public.conversations c ON c.id = o.conversation_id
                   WHERE o.conversation_id = NEW.conversation_id AND o.user_id <> NEW.user_id
                     AND c.kind = 'direct' AND public.has_role(o.user_id, 'admin'::public.app_role))
       OR EXISTS (SELECT 1 FROM public.conversations c
                   WHERE c.id = NEW.conversation_id AND c.kind = 'direct'
                     AND c.created_by <> NEW.user_id AND public.has_role(c.created_by, 'admin'::public.app_role))) THEN
    NEW.folder := 'inbox';
  END IF;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_official_folder() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER conversation_members_official_folder
  BEFORE INSERT OR UPDATE OF folder ON public.conversation_members
  FOR EACH ROW EXECUTE FUNCTION public.message_official_folder();

-- ── 2. move existing rows ──────────────────────────────────────────────────
WITH moved AS (
  SELECT cm.conversation_id, cm.user_id, cm.folder
    FROM public.conversation_members cm
   WHERE cm.folder <> 'inbox'
     AND (public.has_role(cm.user_id, 'admin'::public.app_role)
          OR EXISTS (SELECT 1 FROM public.conversation_members o
                       JOIN public.conversations c ON c.id = o.conversation_id
                      WHERE o.conversation_id = cm.conversation_id AND o.user_id <> cm.user_id
                        AND c.kind = 'direct' AND public.has_role(o.user_id, 'admin'::public.app_role)))
)
INSERT INTO public.message_m32_backup (kind, conversation_id, user_id, old_folder)
SELECT 'folder', conversation_id, user_id, folder FROM moved;

UPDATE public.conversation_members cm
   SET folder = 'inbox'
  FROM public.message_m32_backup b
 WHERE b.kind = 'folder' AND b.conversation_id = cm.conversation_id AND b.user_id = cm.user_id;

-- ── 3. nobody can block the official account ───────────────────────────────
CREATE FUNCTION public.user_blocks_official_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.has_role(NEW.blocked_id, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'BLOCK-OFFICIAL: 50mm Retina World cannot be blocked' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION public.user_blocks_official_guard() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER user_blocks_official_guard
  BEFORE INSERT OR UPDATE ON public.user_blocks
  FOR EACH ROW EXECUTE FUNCTION public.user_blocks_official_guard();

INSERT INTO public.message_m32_backup (kind, blocker_id, blocked_id, blocked_at)
SELECT 'block', b.blocker_id, b.blocked_id, b.created_at
  FROM public.user_blocks b
 WHERE public.has_role(b.blocked_id, 'admin'::public.app_role);

DELETE FROM public.user_blocks b
 USING public.message_m32_backup k
 WHERE k.kind = 'block' AND k.blocker_id = b.blocker_id AND k.blocked_id = b.blocked_id;

DO $report$
BEGIN
  RAISE NOTICE 'M32 applied — rows moved to Chats: %, blocks of the official account removed: %',
    (SELECT count(*) FROM public.message_m32_backup WHERE kind = 'folder'),
    (SELECT count(*) FROM public.message_m32_backup WHERE kind = 'block');
END
$report$;

COMMIT;

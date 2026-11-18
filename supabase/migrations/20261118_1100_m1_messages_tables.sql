-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1100 · M1 — private messages: the tables, closed by default
-- Owner decisions 15 Nov 2026 (plan "Job Engine and Messages Work Plan", M section);
-- design: docs/messages/M0_DATA_MODEL.md.
--
-- THIS FILE IS TABLES + ROW RULES ONLY. No send function (M2), no switch
-- functions (M2b), no word guard logic (M2c). After it:
--   * nobody can send a message (there is no door yet);
--   * message_control is seeded 'allowed_selected' with an EMPTY list = nobody
--     allowed (the Owner is added in M2b);
--   * members can READ only chats they belong to; they can WRITE nothing.
--
-- API ACCESS. authenticated gets SELECT on 4 tables (conversations,
-- conversation_members, messages, message_attachments), each limited by a row
-- rule to the member's own chats. Every other new table has no API grant at all.
-- service_role gets ALL (the job engine and the later functions run there).
-- No member has INSERT / UPDATE / DELETE on anything here.
--
-- NO DELETE, NO UNSEND. A trigger refuses DELETE and any UPDATE of a message
-- (except held → sent / rejected, the admin review of the word guard) whenever
-- a signed-in actor is behind it. Only service / cron work (no auth.uid(): the
-- 180-day retention job, admin full wipe) may delete.
--
-- RETENTION FLAG for the account-deletion unit: messages.sender_id and
-- conversation_members.user_id have NO foreign key to auth.users on purpose —
-- a deleted member's messages stay hidden 180 days (Owner rule), so they must
-- not cascade away. delete-user / delete-my-account must call a wipe function
-- (added with the retention job) for the "admin delete = instant full wipe" rule.
--
-- The account guard (A1) is attached to the 4 tables a member-run function will
-- write, so an account under review cannot send even through a DEFINER door.
--
-- Rollback: supabase/rollback/20261118_1100_m1_messages_tables_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1100_m1_messages_tables.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.conversations') IS NOT NULL OR to_regclass('public.messages') IS NOT NULL THEN
    RAISE EXCEPTION 'M1-PRE-001: messages tables already exist — not re-applying';
  END IF;
  IF to_regprocedure('public.account_state_guard()') IS NULL OR to_regprocedure('public.has_role(uuid,public.app_role)') IS NULL THEN
    RAISE EXCEPTION 'M1-PRE-002: account_state_guard() or has_role() is missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. control (who may message; per-member rules) ─────────────────────────
CREATE TABLE public.message_control (
  id              boolean PRIMARY KEY DEFAULT true CHECK (id),          -- one row only
  mode            text NOT NULL DEFAULT 'allowed_selected'
                  CHECK (mode IN ('allowed_all', 'allowed_selected', 'blocked_all', 'blocked_selected')),
  groups_enabled  boolean NOT NULL DEFAULT false,
  note            text CHECK (note IS NULL OR char_length(note) <= 500),
  updated_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.message_control (id, mode, groups_enabled) VALUES (true, 'allowed_selected', false);

CREATE TABLE public.message_control_members (
  user_id    uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  listed_by  uuid,
  listed_at  timestamptz NOT NULL DEFAULT now(),
  note       text CHECK (note IS NULL OR char_length(note) <= 500)
);

CREATE TABLE public.message_member_rules (
  user_id        uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  text_ok        boolean NOT NULL DEFAULT true,
  photos_ok      boolean NOT NULL DEFAULT true,
  groups_ok      boolean NOT NULL DEFAULT true,
  friends_only   boolean NOT NULL DEFAULT false,
  daily_limit    integer CHECK (daily_limit IS NULL OR daily_limit BETWEEN 0 AND 100000),
  blocked_until  timestamptz,
  reason         text CHECK (reason IS NULL OR char_length(reason) <= 500),
  set_by         uuid,
  set_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.message_control_log (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  actor_id   uuid,
  area       text NOT NULL CHECK (area IN ('mode', 'groups', 'list', 'member_rule', 'word_rule')),
  user_id    uuid,
  old_value  text,
  new_value  text,
  reason     text NOT NULL CHECK (btrim(reason) <> '' AND char_length(reason) <= 500)
);
-- P28: message_control_log · a few rows per admin change · admin history reads newest first
CREATE INDEX message_control_log_at_idx ON public.message_control_log (at DESC);

-- ── 2. chats ───────────────────────────────────────────────────────────────
CREATE TABLE public.conversations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind             text NOT NULL CHECK (kind IN ('direct', 'group')),
  direct_key       text UNIQUE,                       -- least(a,b)||':'||greatest(a,b): one chat per pair
  title            text CHECK (title IS NULL OR char_length(title) <= 120),
  created_by       uuid NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_message_at  timestamptz,
  CONSTRAINT conversations_direct_key CHECK ((kind = 'direct') = (direct_key IS NOT NULL))
);

CREATE TABLE public.conversation_members (
  conversation_id  uuid NOT NULL REFERENCES public.conversations (id) ON DELETE CASCADE,
  user_id          uuid NOT NULL,                     -- no FK on purpose (see header)
  role             text NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'owner')),
  folder           text NOT NULL DEFAULT 'inbox' CHECK (folder IN ('inbox', 'requests', 'declined')),
  joined_at        timestamptz NOT NULL DEFAULT now(),
  last_read_at     timestamptz,
  muted            boolean NOT NULL DEFAULT false,
  PRIMARY KEY (conversation_id, user_id)
);
-- P28: conversation_members · one row per member per chat · the inbox / requests list reads one member's folder
CREATE INDEX conversation_members_user_idx ON public.conversation_members (user_id, folder);

CREATE TABLE public.messages (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id  uuid NOT NULL REFERENCES public.conversations (id) ON DELETE CASCADE,
  sender_id        uuid NOT NULL,                     -- no FK on purpose (see header)
  kind             text NOT NULL DEFAULT 'text' CHECK (kind IN ('text', 'photo')),
  body             text NOT NULL DEFAULT '' CHECK (char_length(body) <= 4000),
  client_msg_id    uuid NOT NULL,
  status           text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'held', 'rejected')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT messages_text_needs_body CHECK (kind = 'photo' OR btrim(body) <> ''),
  CONSTRAINT messages_never_twice UNIQUE (sender_id, client_msg_id)
);
-- P28: messages · grows with chat volume · reading one chat, newest first, page by page
CREATE INDEX messages_conversation_idx ON public.messages (conversation_id, id DESC);
-- P28: messages · grows with chat volume · the per-minute / per-day send limits count one sender's recent rows
CREATE INDEX messages_sender_time_idx ON public.messages (sender_id, created_at DESC);
-- P28: messages · only held rows (a handful) · the admin review queue of the word guard
CREATE INDEX messages_held_idx ON public.messages (created_at) WHERE status = 'held';

CREATE TABLE public.message_attachments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id    bigint NOT NULL REFERENCES public.messages (id) ON DELETE CASCADE,
  storage_path  text NOT NULL,
  mime          text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  bytes         integer NOT NULL CHECK (bytes BETWEEN 1 AND 15000000),
  width         integer,
  height        integer,
  created_at    timestamptz NOT NULL DEFAULT now()
);
-- P28: message_attachments · a fraction of messages · loading a message's photos
CREATE INDEX message_attachments_message_idx ON public.message_attachments (message_id);

-- ── 3. safety (word guard, guard events, admin reads) ──────────────────────
CREATE TABLE public.message_word_rules (
  id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  category  text NOT NULL CHECK (category IN ('abuse', 'threat', 'political', 'self_harm', 'abnormal')),
  pattern   text NOT NULL CHECK (char_length(pattern) BETWEEN 1 AND 200),
  lang      text,
  action    text NOT NULL CHECK (action IN ('block', 'hold', 'help')),
  active    boolean NOT NULL DEFAULT true,
  added_by  uuid,
  added_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.message_guard_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid NOT NULL,
  rule_id     bigint,
  action      text NOT NULL CHECK (action IN ('block', 'hold', 'help')),
  message_id  bigint,
  created_at  timestamptz NOT NULL DEFAULT now()
);
-- P28: message_guard_events · only word-guard hits (rare) · admin looks up one member's hits newest first
CREATE INDEX message_guard_events_user_idx ON public.message_guard_events (user_id, created_at DESC);

CREATE TABLE public.message_admin_reads (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  admin_id         uuid NOT NULL,
  conversation_id  uuid NOT NULL,
  reason           text NOT NULL CHECK (btrim(reason) <> '' AND char_length(reason) <= 500),
  at               timestamptz NOT NULL DEFAULT now()
);
-- P28: message_admin_reads · a few per admin per day · the rogue-admin alarm counts one admin's opens per day
CREATE INDEX message_admin_reads_admin_idx ON public.message_admin_reads (admin_id, at DESC);
-- P28: message_admin_reads · a few per admin per day · "who opened this chat" for the member-facing audit
CREATE INDEX message_admin_reads_conv_idx ON public.message_admin_reads (conversation_id, at DESC);

-- ── 4. append-only logs, and no delete / unsend on messages ────────────────
CREATE FUNCTION public.message_log_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $fn$
BEGIN
  RAISE EXCEPTION '% is append-only (% refused)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
END
$fn$;
CREATE TRIGGER message_control_log_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON public.message_control_log
  FOR EACH STATEMENT EXECUTE FUNCTION public.message_log_append_only();
CREATE TRIGGER message_admin_reads_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON public.message_admin_reads
  FOR EACH STATEMENT EXECUTE FUNCTION public.message_log_append_only();
CREATE TRIGGER message_guard_events_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON public.message_guard_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.message_log_append_only();

CREATE FUNCTION public.messages_no_delete_no_unsend()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $fn$
BEGIN
  -- service / cron work (no signed-in actor) may delete: 180-day retention, admin full wipe
  IF auth.uid() IS NULL THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.status = 'held' AND NEW.status IN ('sent', 'rejected')
     AND (NEW.id, NEW.conversation_id, NEW.sender_id, NEW.kind, NEW.body, NEW.client_msg_id, NEW.created_at)
         IS NOT DISTINCT FROM (OLD.id, OLD.conversation_id, OLD.sender_id, OLD.kind, OLD.body, OLD.client_msg_id, OLD.created_at) THEN
    RETURN NEW;                                       -- admin review of a held message: the status only
  END IF;
  RAISE EXCEPTION 'MESSAGE_IMMUTABLE: messages cannot be edited, deleted or unsent' USING ERRCODE = 'insufficient_privilege';
END
$fn$;
CREATE TRIGGER messages_no_delete_no_unsend BEFORE UPDATE OR DELETE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.messages_no_delete_no_unsend();

-- ── 5. who is in a chat (used by the row rules; no uid argument → no probing) ──
CREATE FUNCTION public.is_conversation_member(_conversation_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.conversation_members m
                  WHERE m.conversation_id = _conversation_id AND m.user_id = (SELECT auth.uid()));
$fn$;

-- ── 6. rights ──────────────────────────────────────────────────────────────
ALTER TABLE public.message_control         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_control_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_member_rules    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_control_log     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_members    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_attachments     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_word_rules      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_guard_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_admin_reads     ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.message_control, public.message_control_members, public.message_member_rules,
              public.message_control_log, public.conversations, public.conversation_members, public.messages,
              public.message_attachments, public.message_word_rules, public.message_guard_events,
              public.message_admin_reads FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_control, public.message_control_members, public.message_member_rules,
             public.message_control_log, public.conversations, public.conversation_members, public.messages,
             public.message_attachments, public.message_word_rules, public.message_guard_events,
             public.message_admin_reads TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

GRANT SELECT ON public.conversations, public.conversation_members, public.messages, public.message_attachments TO authenticated;

CREATE POLICY "conversation_members: own rows" ON public.conversation_members
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY "conversations: member only" ON public.conversations
  FOR SELECT TO authenticated USING (public.is_conversation_member(id));
CREATE POLICY "messages: member reads sent, sender sees own held" ON public.messages
  FOR SELECT TO authenticated
  USING (public.is_conversation_member(conversation_id)
         AND (status = 'sent' OR sender_id = (SELECT auth.uid())));
CREATE POLICY "message_attachments: member of the message's chat" ON public.message_attachments
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.messages m
                  WHERE m.id = message_id
                    AND public.is_conversation_member(m.conversation_id)
                    AND (m.status = 'sent' OR m.sender_id = (SELECT auth.uid()))));

REVOKE ALL ON FUNCTION public.message_log_append_only() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.messages_no_delete_no_unsend() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_conversation_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_conversation_member(uuid) TO authenticated, service_role;

-- ── 7. the account guard on the tables the send door will write ────────────
DO $attach$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['conversations', 'conversation_members', 'messages', 'message_attachments'] LOOP
    EXECUTE format('CREATE TRIGGER zz_account_state_guard BEFORE INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.account_state_guard()', t);
  END LOOP;
END
$attach$;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2400 · M13 — message ticks: sent · delivered · read
-- Owner order 21 Nov 2026: "single tick grey = sent, double tick grey = delivered, double tick BLUE = read".
--
--   sent       = the message is stored (always true for a message the thread shows)
--   delivered  = the other person's app has fetched it: conversation_members.last_delivered_at (new),
--                set by message_mark_delivered() which the member's app calls when its inbox badge loads
--   read       = the other person opened the chat after the message: last_read_at (as before)
--   In a group a tick is only as far as the LEAST advanced member (all delivered / all read).
--
--   message_thread (and admin_view_thread, kept byte-identical to it — PROBE_2200 D3) now carries, for the
--   viewer's OWN messages only, a field "tick": 'sent' | 'delivered' | 'read'. Other people's messages carry none.
--   message_mark_read also counts as delivered. Nothing about who has read what is shown to anyone else:
--   a tick is only ever shown to the sender of that message.
--
-- Rollback: supabase/rollback/20261118_2400_m13_ticks_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2400_m13_ticks.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.admin_view_thread(uuid,uuid,bigint,integer)') IS NULL THEN
    RAISE EXCEPTION 'M13-PRE-001: M11 (20261118_2200) is not applied';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'conversation_members' AND column_name = 'last_delivered_at') THEN
    RAISE EXCEPTION 'M13-PRE-002: last_delivered_at already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. when this member's app last fetched the chat ────────────────────────
ALTER TABLE public.conversation_members ADD COLUMN last_delivered_at timestamptz;

-- ── 2. the member's app says "my inbox is loaded" ──────────────────────────
-- Marks every chat of the caller that has a message newer than the last mark. A no-op (zero rows) when nothing is new.
CREATE FUNCTION public.message_mark_delivered()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid()); _n integer;
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  UPDATE public.conversation_members cm SET last_delivered_at = now()
    FROM public.conversations c
   WHERE cm.user_id = _me AND cm.folder <> 'declined' AND c.id = cm.conversation_id
     AND c.last_message_at IS NOT NULL
     AND c.last_message_at > coalesce(cm.last_delivered_at, cm.joined_at);
  GET DIAGNOSTICS _n = ROW_COUNT;
  RETURN _n;
END
$fn$;

-- reading a chat is also delivery
CREATE OR REPLACE FUNCTION public.message_mark_read(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET last_read_at = now(), last_delivered_at = now()
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid());
  RETURN FOUND;
END
$fn$;

-- ── 3. the tick of one message, seen by its sender ─────────────────────────
-- Pure read helper (not callable by the app): the least advanced OTHER member decides.
CREATE FUNCTION public.message_tick(_conversation uuid, _sender uuid, _created timestamptz)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN count(*) = 0 THEN 'sent'
    WHEN bool_and(coalesce(cm.last_read_at, '-infinity'::timestamptz) >= _created) THEN 'read'
    WHEN bool_and(greatest(coalesce(cm.last_delivered_at, '-infinity'::timestamptz), coalesce(cm.last_read_at, '-infinity'::timestamptz)) >= _created) THEN 'delivered'
    ELSE 'sent' END
    FROM public.conversation_members cm
   WHERE cm.conversation_id = _conversation AND cm.user_id <> _sender
$fn$;
REVOKE ALL ON FUNCTION public.message_tick(uuid, uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_tick(uuid, uuid, timestamptz) TO service_role;

-- ── 4. the thread carries the ticks (the member's own, and the admin's identical view of it) ─────
CREATE OR REPLACE FUNCTION public.message_thread(_conversation uuid, _before_id bigint DEFAULT NULL, _limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid());
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.conversation_members cm WHERE cm.conversation_id = _conversation AND cm.user_id = _me) THEN
    RAISE EXCEPTION 'MSG-071: not your chat' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', m.body,
                                        'created_at', m.created_at, 'status', CASE WHEN m.sender_id = _me THEN m.status ELSE 'sent' END,
                                        'tick', CASE WHEN m.sender_id = _me AND m.status = 'sent' THEN public.message_tick(_conversation, _me, m.created_at) END,
                                        'photos', coalesce((SELECT jsonb_agg(jsonb_build_object('path', a.storage_path, 'width', a.width, 'height', a.height) ORDER BY a.created_at, a.id)
                                                              FROM public.message_attachments a WHERE a.message_id = m.id), '[]'::jsonb))
                     ORDER BY m.id DESC)
      FROM (SELECT * FROM public.messages m2
             WHERE m2.conversation_id = _conversation
               AND (m2.status = 'sent' OR (m2.sender_id = _me AND m2.status = 'held'))
               AND (_before_id IS NULL OR m2.id < _before_id)
             ORDER BY m2.id DESC LIMIT least(greatest(coalesce(_limit, 50), 1), 100)) m), '[]'::jsonb);
END
$fn$;

CREATE OR REPLACE FUNCTION public.admin_view_thread(_user uuid, _conversation uuid, _before_id bigint DEFAULT NULL, _limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can open a message box' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _user IS NULL OR NOT EXISTS (SELECT 1 FROM public.conversation_members cm WHERE cm.conversation_id = _conversation AND cm.user_id = _user) THEN
    RAISE EXCEPTION 'MSG-071: not this member''s chat' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', m.body,
                                        'created_at', m.created_at, 'status', CASE WHEN m.sender_id = _user THEN m.status ELSE 'sent' END,
                                        'tick', CASE WHEN m.sender_id = _user AND m.status = 'sent' THEN public.message_tick(_conversation, _user, m.created_at) END,
                                        'photos', coalesce((SELECT jsonb_agg(jsonb_build_object('path', a.storage_path, 'width', a.width, 'height', a.height) ORDER BY a.created_at, a.id)
                                                              FROM public.message_attachments a WHERE a.message_id = m.id), '[]'::jsonb))
                     ORDER BY m.id DESC)
      FROM (SELECT * FROM public.messages m2
             WHERE m2.conversation_id = _conversation
               AND (m2.status = 'sent' OR (m2.sender_id = _user AND m2.status = 'held'))
               AND (_before_id IS NULL OR m2.id < _before_id)
             ORDER BY m2.id DESC LIMIT least(greatest(coalesce(_limit, 50), 1), 100)) m), '[]'::jsonb);
END
$fn$;

-- ── 4b. the inbox row: the last message, when it is yours, carries its tick ─────
CREATE OR REPLACE FUNCTION public.message_my_conversations(_folder text DEFAULT 'inbox', _limit integer DEFAULT 30, _before timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := (SELECT auth.uid());
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF _folder NOT IN ('inbox', 'requests') THEN
    RAISE EXCEPTION 'MSG-070: folder must be inbox or requests' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.sort_at DESC NULLS LAST) FROM (
      SELECT coalesce(c.last_message_at, c.created_at) AS sort_at,
             jsonb_build_object(
               'conversation_id', c.id,
               'kind', c.kind,
               'title', c.title,
               'folder', cm.folder,
               'muted', cm.muted,
               'last_message_at', c.last_message_at,
               'other', (SELECT jsonb_build_object('user_id', o.user_id, 'full_name', p.full_name, 'username', p.custom_url, 'avatar_url', p.avatar_url)
                           FROM public.conversation_members o LEFT JOIN public.profiles p ON p.id = o.user_id
                          WHERE o.conversation_id = c.id AND o.user_id <> _me ORDER BY o.joined_at LIMIT 1),
               'last', (SELECT jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', left(m.body, 200), 'created_at', m.created_at,
                                                  'tick', CASE WHEN m.sender_id = _me AND m.status = 'sent' THEN public.message_tick(c.id, _me, m.created_at) END)
                          FROM public.messages m
                         WHERE m.conversation_id = c.id AND (m.status = 'sent' OR (m.sender_id = _me AND m.status = 'held'))
                         ORDER BY m.id DESC LIMIT 1),
               'unread', (SELECT count(*) FROM public.messages m
                           WHERE m.conversation_id = c.id AND m.sender_id <> _me AND m.status = 'sent'
                             AND m.created_at > coalesce(cm.last_read_at, cm.joined_at))
             ) AS j
        FROM public.conversation_members cm
        JOIN public.conversations c ON c.id = cm.conversation_id
       WHERE cm.user_id = _me AND cm.folder = _folder
         AND (_before IS NULL OR coalesce(c.last_message_at, c.created_at) < _before)
         AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = 'sent' OR m.sender_id = _me))
       ORDER BY coalesce(c.last_message_at, c.created_at) DESC
       LIMIT least(greatest(coalesce(_limit, 30), 1), 100)
    ) x), '[]'::jsonb);
END
$fn$;

CREATE OR REPLACE FUNCTION public.admin_view_inbox(_user uuid, _folder text DEFAULT 'inbox', _limit integer DEFAULT 30, _before timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can open a message box' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _user IS NULL THEN
    RAISE EXCEPTION 'MSGADM-004: no such member' USING ERRCODE = 'no_data_found';
  END IF;
  IF _folder NOT IN ('inbox', 'requests') THEN
    RAISE EXCEPTION 'MSG-070: folder must be inbox or requests' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.sort_at DESC NULLS LAST) FROM (
      SELECT coalesce(c.last_message_at, c.created_at) AS sort_at,
             jsonb_build_object(
               'conversation_id', c.id,
               'kind', c.kind,
               'title', c.title,
               'folder', cm.folder,
               'muted', cm.muted,
               'last_message_at', c.last_message_at,
               'other', (SELECT jsonb_build_object('user_id', o.user_id, 'full_name', p.full_name, 'username', p.custom_url, 'avatar_url', p.avatar_url)
                           FROM public.conversation_members o LEFT JOIN public.profiles p ON p.id = o.user_id
                          WHERE o.conversation_id = c.id AND o.user_id <> _user ORDER BY o.joined_at LIMIT 1),
               'last', (SELECT jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', left(m.body, 200), 'created_at', m.created_at,
                                                  'tick', CASE WHEN m.sender_id = _user AND m.status = 'sent' THEN public.message_tick(c.id, _user, m.created_at) END)
                          FROM public.messages m
                         WHERE m.conversation_id = c.id AND (m.status = 'sent' OR (m.sender_id = _user AND m.status = 'held'))
                         ORDER BY m.id DESC LIMIT 1),
               'unread', (SELECT count(*) FROM public.messages m
                           WHERE m.conversation_id = c.id AND m.sender_id <> _user AND m.status = 'sent'
                             AND m.created_at > coalesce(cm.last_read_at, cm.joined_at))
             ) AS j
        FROM public.conversation_members cm
        JOIN public.conversations c ON c.id = cm.conversation_id
       WHERE cm.user_id = _user AND cm.folder = _folder
         AND (_before IS NULL OR coalesce(c.last_message_at, c.created_at) < _before)
         AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = c.id AND (m.status = 'sent' OR m.sender_id = _user))
       ORDER BY coalesce(c.last_message_at, c.created_at) DESC
       LIMIT least(greatest(coalesce(_limit, 30), 1), 100)
    ) x), '[]'::jsonb);
END
$fn$;

-- ── 5. rights (CREATE OR REPLACE keeps the old grants; stated again so this file stands alone) ──
REVOKE ALL ON FUNCTION public.message_my_conversations(text, integer, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_view_inbox(uuid, text, integer, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_my_conversations(text, integer, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_view_inbox(uuid, text, integer, timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.message_mark_delivered() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_mark_read(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_thread(uuid, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_mark_delivered() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_mark_read(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_thread(uuid, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) TO authenticated, service_role;

COMMIT;

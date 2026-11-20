-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1600 · M4 — inbox, requests, thread, read state (the shared data layer)
-- Needs M1 + M2. One set of functions the app's single messages store will call —
-- screens never read the tables directly (Owner rule: one data layer).
-- READING never checks the admin switch or the account state: a member whose access
-- was withdrawn, or whose account is under review, can still read old chats
-- (Owner decision). WRITING the member's own read state / folder is guarded by the
-- account guard like any other member write.
--   message_my_conversations(folder, limit, before) — inbox / requests list: other member,
--       last message, unread count, muted; newest first
--   message_thread(conversation, before_id, limit)  — one chat's messages, newest first
--   message_unread_counts()                         — {inbox, requests} for the badge
--   message_mark_read(conversation)
--   message_accept_request(conversation) / message_decline_request(conversation)
--   message_set_muted(conversation, muted)
-- Held messages are visible only to their sender; rejected ones to nobody.
--
-- Rollback: supabase/rollback/20261118_1600_m4_message_inbox_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1600_m4_message_inbox.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.conversation_members') IS NULL THEN
    RAISE EXCEPTION 'M4-PRE-001: M1 (20261118_1100) is not applied';
  END IF;
  IF to_regprocedure('public.message_my_conversations(text,integer,timestamptz)') IS NOT NULL THEN
    RAISE EXCEPTION 'M4-PRE-002: message_my_conversations already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

CREATE FUNCTION public.message_my_conversations(_folder text DEFAULT 'inbox', _limit integer DEFAULT 30, _before timestamptz DEFAULT NULL)
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
               'last', (SELECT jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', left(m.body, 200), 'created_at', m.created_at)
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

CREATE FUNCTION public.message_thread(_conversation uuid, _before_id bigint DEFAULT NULL, _limit integer DEFAULT 50)
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
                                        'created_at', m.created_at, 'status', CASE WHEN m.sender_id = _me THEN m.status ELSE 'sent' END)
                     ORDER BY m.id DESC)
      FROM (SELECT * FROM public.messages m2
             WHERE m2.conversation_id = _conversation
               AND (m2.status = 'sent' OR (m2.sender_id = _me AND m2.status = 'held'))
               AND (_before_id IS NULL OR m2.id < _before_id)
             ORDER BY m2.id DESC LIMIT least(greatest(coalesce(_limit, 50), 1), 100)) m), '[]'::jsonb);
END
$fn$;

CREATE FUNCTION public.message_unread_counts()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object(
    'inbox', coalesce((SELECT count(DISTINCT cm.conversation_id) FROM public.conversation_members cm
                        WHERE cm.user_id = (SELECT auth.uid()) AND cm.folder = 'inbox' AND NOT cm.muted
                          AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = cm.conversation_id
                                       AND m.sender_id <> cm.user_id AND m.status = 'sent'
                                       AND m.created_at > coalesce(cm.last_read_at, cm.joined_at))), 0),
    'requests', coalesce((SELECT count(*) FROM public.conversation_members cm
                           WHERE cm.user_id = (SELECT auth.uid()) AND cm.folder = 'requests'
                             AND EXISTS (SELECT 1 FROM public.messages m WHERE m.conversation_id = cm.conversation_id
                                          AND m.sender_id <> cm.user_id AND m.status = 'sent')), 0));
$fn$;

CREATE FUNCTION public.message_mark_read(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET last_read_at = now() WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid());
  RETURN FOUND;
END
$fn$;

CREATE FUNCTION public.message_accept_request(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET folder = 'inbox'
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid()) AND folder IN ('requests', 'declined');
  RETURN FOUND;
END
$fn$;

CREATE FUNCTION public.message_decline_request(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET folder = 'declined'
   WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid()) AND folder = 'requests';
  RETURN FOUND;
END
$fn$;

CREATE FUNCTION public.message_set_muted(_conversation uuid, _muted boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.conversation_members SET muted = coalesce(_muted, false) WHERE conversation_id = _conversation AND user_id = (SELECT auth.uid());
  RETURN FOUND;
END
$fn$;

REVOKE ALL ON FUNCTION public.message_my_conversations(text, integer, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_thread(uuid, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_unread_counts() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_mark_read(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_accept_request(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_decline_request(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_set_muted(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_my_conversations(text, integer, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_thread(uuid, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_unread_counts() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_mark_read(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_accept_request(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_decline_request(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_set_muted(uuid, boolean) TO authenticated, service_role;

COMMIT;

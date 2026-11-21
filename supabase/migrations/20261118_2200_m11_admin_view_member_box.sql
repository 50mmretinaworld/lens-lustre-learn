-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2200 · M11 — admin opens a member's message box (read-only, as the member sees it)
-- Owner order 21 Nov 2026: "search any member, go straight into his message box, stay unlimited time,
-- no alarm, nothing needed — the same message box the member sees."
--
--   admin_view_inbox(user, folder, limit, before)         = message_my_conversations, for that member
--   admin_view_thread(user, conversation, before, limit)  = message_thread, for that member
--       both ADMIN ONLY, write NOTHING (no log row, no read mark, no alarm), and answer with exactly
--       the shape the member's own screen gets, so the admin page reuses the member's screens.
--   admin_message_member_search(q, filter, sort, dir, limit, offset)
--       the searchable, sortable, filterable member table: name / @username / e-mail search,
--       filters all · with chats · reported · paused · on the list, filter counts, paging.
--   message_photo_visible: an admin can open any chat photo (no 10-minute window any more).
--
-- Rollback: supabase/rollback/20261118_2200_m11_admin_view_member_box_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2200_m11_admin_view_member_box.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_reports') IS NULL THEN
    RAISE EXCEPTION 'M11-PRE-001: M10 (20261118_2100) is not applied';
  END IF;
  IF to_regprocedure('public.admin_view_inbox(uuid,text,integer,timestamptz)') IS NOT NULL THEN
    RAISE EXCEPTION 'M11-PRE-002: admin_view_inbox already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. the member's inbox, seen by an admin ────────────────────────────────
CREATE FUNCTION public.admin_view_inbox(_user uuid, _folder text DEFAULT 'inbox', _limit integer DEFAULT 30, _before timestamptz DEFAULT NULL)
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
               'last', (SELECT jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'kind', m.kind, 'body', left(m.body, 200), 'created_at', m.created_at)
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

-- ── 2. one of the member's chats, seen by an admin ─────────────────────────
CREATE FUNCTION public.admin_view_thread(_user uuid, _conversation uuid, _before_id bigint DEFAULT NULL, _limit integer DEFAULT 50)
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

-- ── 3. photos: an admin can open any chat photo ────────────────────────────
CREATE OR REPLACE FUNCTION public.message_photo_visible(_path text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL AND (
    ((storage.foldername(_path))[1] = (SELECT auth.uid())::text)
    OR EXISTS (SELECT 1 FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
                WHERE a.storage_path = _path
                  AND public.is_conversation_member(m.conversation_id)
                  AND (m.status = 'sent' OR m.sender_id = (SELECT auth.uid())))
    OR (public.has_role((SELECT auth.uid()), 'admin'::public.app_role)
        AND EXISTS (SELECT 1 FROM public.message_attachments a WHERE a.storage_path = _path)));
$fn$;

-- ── 4. the member table (search · filter · sort · page) ────────────────────
CREATE FUNCTION public.admin_message_member_search(
  _q text DEFAULT NULL, _filter text DEFAULT 'all', _sort text DEFAULT 'name', _dir text DEFAULT 'asc',
  _limit integer DEFAULT 25, _offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := (SELECT auth.uid());
  _needle text := lower(btrim(coalesce(_q, '')));
  _desc boolean := lower(coalesce(_dir, 'asc')) = 'desc';
  _lim integer := least(greatest(coalesce(_limit, 25), 1), 100);
  _off integer := greatest(coalesce(_offset, 0), 0);
  _res jsonb;
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can search members here' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _filter NOT IN ('all', 'active', 'reported', 'paused', 'listed') THEN
    RAISE EXCEPTION 'MSGADM-010: filter must be all, active, reported, paused or listed' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _sort NOT IN ('name', 'chats', 'last', 'reports', 'joined') THEN
    RAISE EXCEPTION 'MSGADM-010: sort must be name, chats, last, reports or joined' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  WITH act AS (
    SELECT cm.user_id, count(*) AS chats, max(c.last_message_at) AS last_at
      FROM public.conversation_members cm JOIN public.conversations c ON c.id = cm.conversation_id
     GROUP BY cm.user_id),
  rep AS (
    SELECT r.reported_user_id AS user_id, count(*) AS n
      FROM public.message_reports r
     WHERE r.reported_user_id IS NOT NULL AND r.created_at > now() - interval '30 days'
     GROUP BY r.reported_user_id),
  base AS (
    SELECT p.id AS user_id, p.full_name, p.custom_url AS username, p.avatar_url, u.email::text AS email, p.created_at AS joined_at,
           coalesce(a.chats, 0) AS chats, a.last_at, coalesce(r.n, 0) AS reports_30d,
           EXISTS (SELECT 1 FROM public.message_control_members l WHERE l.user_id = p.id) AS listed,
           coalesce((SELECT mr.blocked_until > now() FROM public.message_member_rules mr WHERE mr.user_id = p.id), false) AS paused,
           EXISTS (SELECT 1 FROM public.message_member_rules mr WHERE mr.user_id = p.id) AS has_rules
      FROM public.profiles p
      JOIN auth.users u ON u.id = p.id
      LEFT JOIN act a ON a.user_id = p.id
      LEFT JOIN rep r ON r.user_id = p.id
     WHERE _needle = ''
        OR position(_needle in lower(coalesce(p.full_name, ''))) > 0
        OR position(_needle in lower(coalesce(p.custom_url, ''))) > 0
        OR position(_needle in lower(coalesce(u.email::text, ''))) > 0),
  shown AS (
    SELECT * FROM base b
     WHERE CASE _filter WHEN 'active' THEN b.chats > 0 WHEN 'reported' THEN b.reports_30d > 0
                        WHEN 'paused' THEN b.paused WHEN 'listed' THEN b.listed ELSE true END),
  page AS (
    SELECT * FROM shown s
     ORDER BY (CASE WHEN _sort = 'name'    AND NOT _desc THEN lower(coalesce(s.full_name, '')) END) ASC,
              (CASE WHEN _sort = 'name'    AND _desc     THEN lower(coalesce(s.full_name, '')) END) DESC,
              (CASE WHEN _sort = 'chats'   AND NOT _desc THEN s.chats END) ASC,
              (CASE WHEN _sort = 'chats'   AND _desc     THEN s.chats END) DESC,
              (CASE WHEN _sort = 'reports' AND NOT _desc THEN s.reports_30d END) ASC,
              (CASE WHEN _sort = 'reports' AND _desc     THEN s.reports_30d END) DESC,
              (CASE WHEN _sort = 'last'    AND NOT _desc THEN s.last_at END) ASC NULLS LAST,
              (CASE WHEN _sort = 'last'    AND _desc     THEN s.last_at END) DESC NULLS LAST,
              (CASE WHEN _sort = 'joined'  AND NOT _desc THEN s.joined_at END) ASC,
              (CASE WHEN _sort = 'joined'  AND _desc     THEN s.joined_at END) DESC,
              s.user_id
     LIMIT _lim OFFSET _off)
  SELECT jsonb_build_object(
           'total', (SELECT count(*) FROM shown),
           'counts', jsonb_build_object(
              'all', (SELECT count(*) FROM base),
              'active', (SELECT count(*) FROM base WHERE chats > 0),
              'reported', (SELECT count(*) FROM base WHERE reports_30d > 0),
              'paused', (SELECT count(*) FROM base WHERE paused),
              'listed', (SELECT count(*) FROM base WHERE listed)),
           'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
                      'user_id', g.user_id, 'full_name', g.full_name, 'username', g.username, 'avatar_url', g.avatar_url, 'email', g.email,
                      'joined_at', g.joined_at, 'chats', g.chats, 'last_message_at', g.last_at, 'reports_30d', g.reports_30d,
                      'listed', g.listed, 'paused', g.paused, 'has_rules', g.has_rules,
                      'is_admin', public.has_role(g.user_id, 'admin'::public.app_role))) FROM page g), '[]'::jsonb))
    INTO _res;
  RETURN _res;
END
$fn$;

-- ── 5. rights ──────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.admin_view_inbox(uuid, text, integer, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_member_search(text, text, text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_view_inbox(uuid, text, integer, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_view_thread(uuid, uuid, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_message_member_search(text, text, text, text, integer, integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.message_photo_visible(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_photo_visible(text) TO authenticated, service_role;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_2000 · M8b — the two admin reads the Messages admin page still lacked
-- Needs M2b, M2c, M7. Read-only functions; no new table, no new write path.
--
--   admin_message_word_rules()
--       the word list (all rules, active or not) for the admin page. Admin only.
--       The table has no API grant, so this is the only way the page can list it.
--   admin_message_member_chats(_user, _reason)
--       the chats ONE member is in: chat id, kind, title, last message time, message
--       count, the other members' names. NEVER message text (that is the logged viewer,
--       admin_read_conversation). A reason (1–500 characters) is required and the look-up
--       is written to message_control_log (area 'lookup') before the list is returned.
--
-- Rollback: supabase/rollback/20261118_2000_m8b_admin_page_reads_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_2000_m8b_admin_page_reads.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_admin_check(text)') IS NULL OR to_regprocedure('public.admin_read_conversation(uuid,text,bigint,integer)') IS NULL THEN
    RAISE EXCEPTION 'M8B-PRE-001: M2b and M7 must be applied first';
  END IF;
  IF to_regprocedure('public.admin_message_word_rules()') IS NOT NULL THEN
    RAISE EXCEPTION 'M8B-PRE-002: admin_message_word_rules already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. the log accepts a chat-list look-up ─────────────────────────────────
ALTER TABLE public.message_control_log DROP CONSTRAINT message_control_log_area_check;
ALTER TABLE public.message_control_log ADD CONSTRAINT message_control_log_area_check
  CHECK (area IN ('mode', 'groups', 'list', 'member_rule', 'word_rule', 'review', 'lookup'));

-- ── 2. the word list ───────────────────────────────────────────────────────
CREATE FUNCTION public.admin_message_word_rules()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can read the word list' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'category', r.category, 'pattern', r.pattern, 'lang', r.lang,
                                                      'action', r.action, 'active', r.active, 'added_at', r.added_at)
                                    ORDER BY r.category, r.pattern)
                     FROM public.message_word_rules r), '[]'::jsonb);
END
$fn$;

-- ── 3. one member's chats (metadata only, logged) ──────────────────────────
CREATE FUNCTION public.admin_message_member_chats(_user uuid, _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason);
BEGIN
  IF _user IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user) THEN
    RAISE EXCEPTION 'MSGADM-004: no such member' USING ERRCODE = 'no_data_found';
  END IF;
  INSERT INTO public.message_control_log (actor_id, area, user_id, old_value, new_value, reason)
  VALUES (_uid, 'lookup', _user, NULL, 'chat list', btrim(_reason));
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'conversation_id', c.id, 'kind', c.kind, 'title', c.title, 'last_message_at', c.last_message_at,
             'messages', (SELECT count(*) FROM public.messages m WHERE m.conversation_id = c.id),
             'others', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', o.user_id, 'full_name', p.full_name, 'username', p.custom_url) ORDER BY p.full_name)
                                   FROM public.conversation_members o LEFT JOIN public.profiles p ON p.id = o.user_id
                                  WHERE o.conversation_id = c.id AND o.user_id <> _user), '[]'::jsonb))
           ORDER BY c.last_message_at DESC NULLS LAST)
      FROM public.conversation_members me JOIN public.conversations c ON c.id = me.conversation_id
     WHERE me.user_id = _user), '[]'::jsonb);
END
$fn$;

-- ── 4. rights ──────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.admin_message_word_rules() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_member_chats(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_message_word_rules() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_message_member_chats(uuid, text) TO authenticated, service_role;

COMMIT;

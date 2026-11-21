-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1900 · M6 — group chats (built, OFF until an admin switches groups on)
-- Needs M1–M5. Owner decisions 15 Nov 2026: groups are built but stay OFF until the admin
-- switches them on (message_admin_set_groups); a group takes only the CREATOR'S friends.
--   message_group_create(title, members[])  — creator + 2..19 of the creator's friends (max 20 in all)
--   message_group_add(conversation, user)   — group owner only; the new member must be the owner's friend
--   message_group_remove(conversation, user)— group owner removes another member
--   message_group_leave(conversation)       — a member leaves (the owner cannot; remove the group by leaving it empty is not offered)
--   message_send_group(conversation, body, client_msg_id) — text; the same checks as the 1:1 door that
--       apply to a group: sign-in, account state, the 4-mode switch, the member's own rules (groups_ok,
--       text_ok, timed block), limits, word guard (block / hold / help), never twice.
-- Every function first checks groups are ON ('MSG-080') and the member may use groups (groups_ok).
-- 20-member cap is a constant here (the plan doc's number was not given to me) — change it in one place.
--
-- Rollback: supabase/rollback/20261118_1900_m6_message_groups_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1900_m6_message_groups.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_send_core(uuid,text,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'M6-PRE-001: M5 (20261118_1700) is not applied';
  END IF;
  IF to_regprocedure('public.message_group_create(text,uuid[])') IS NOT NULL THEN
    RAISE EXCEPTION 'M6-PRE-002: message_group_create already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- the shared opening checks for every group action (returns the caller)
CREATE FUNCTION public.message_group_gate()
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := auth.uid(); _r public.message_member_rules%ROWTYPE;
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF NOT public.account_can_act(_me) THEN
    RAISE EXCEPTION 'ACCOUNT_UNDER_REVIEW' USING ERRCODE = 'insufficient_privilege', DETAIL = 'Your account is under review', HINT = 'support@50mmretina.com';
  END IF;
  IF NOT coalesce((SELECT c.groups_enabled FROM public.message_control c), false) THEN
    RAISE EXCEPTION 'MSG-080: group chats are not available yet' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.message_control_allows(_me) THEN
    RAISE EXCEPTION 'MSG-010: messaging is not available for your account' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO _r FROM public.message_member_rules WHERE user_id = _me;
  IF FOUND AND NOT _r.groups_ok THEN
    RAISE EXCEPTION 'MSG-081: group chats are not available for your account' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF FOUND AND _r.blocked_until IS NOT NULL AND _r.blocked_until > now() THEN
    RAISE EXCEPTION 'MSG-020: messaging is paused for your account until %', to_char(_r.blocked_until, 'YYYY-MM-DD') USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN _me;
END
$fn$;

-- is _other an accepted friend of _me, active, and not blocked either way
CREATE FUNCTION public.message_group_can_take(_me uuid, _other uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT _other IS NOT NULL AND _other <> _me
     AND EXISTS (SELECT 1 FROM public.friendships f WHERE f.status = 'accepted'
                  AND ((f.requester_id = _me AND f.addressee_id = _other) OR (f.requester_id = _other AND f.addressee_id = _me)))
     AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = _other)
     AND public.account_can_act(_other)
     AND NOT EXISTS (SELECT 1 FROM public.user_blocks b WHERE (b.blocker_id = _me AND b.blocked_id = _other) OR (b.blocker_id = _other AND b.blocked_id = _me));
$fn$;

CREATE FUNCTION public.message_group_create(_title text, _members uuid[])
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := public.message_group_gate(); _t text := btrim(coalesce(_title, '')); _u uuid; _conv uuid; _list uuid[];
BEGIN
  IF _t = '' OR char_length(_t) > 120 THEN
    RAISE EXCEPTION 'MSG-082: a group needs a name of 1–120 characters' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT coalesce(array_agg(DISTINCT x), '{}') INTO _list FROM unnest(coalesce(_members, '{}')) x WHERE x IS DISTINCT FROM _me;
  IF cardinality(_list) < 2 OR cardinality(_list) > 19 THEN
    RAISE EXCEPTION 'MSG-083: a group needs 2 to 19 other members' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  FOREACH _u IN ARRAY _list LOOP
    IF NOT public.message_group_can_take(_me, _u) THEN
      RAISE EXCEPTION 'MSG-084: a group can only take your own friends' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM public.conversations c WHERE c.created_by = _me AND c.kind = 'group' AND c.created_at > now() - interval '24 hours') >= 5 THEN
    RAISE EXCEPTION 'MSG-052: too many new chats today' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.conversations (kind, title, created_by) VALUES ('group', _t, _me) RETURNING id INTO _conv;
  INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conv, _me, 'owner', 'inbox');
  INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) SELECT _conv, x, 'member', 'inbox' FROM unnest(_list) x;
  RETURN _conv;
END
$fn$;

CREATE FUNCTION public.message_group_add(_conversation uuid, _user uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := public.message_group_gate();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.conversation_members m JOIN public.conversations c ON c.id = m.conversation_id
                  WHERE m.conversation_id = _conversation AND m.user_id = _me AND m.role = 'owner' AND c.kind = 'group') THEN
    RAISE EXCEPTION 'MSG-085: only the group owner can add members' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (SELECT count(*) FROM public.conversation_members m WHERE m.conversation_id = _conversation) >= 20 THEN
    RAISE EXCEPTION 'MSG-083: the group is full (20 members)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NOT public.message_group_can_take(_me, _user) THEN
    RAISE EXCEPTION 'MSG-084: a group can only take your own friends' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conversation, _user, 'member', 'inbox') ON CONFLICT DO NOTHING;
  RETURN FOUND;
END
$fn$;

CREATE FUNCTION public.message_group_remove(_conversation uuid, _user uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := public.message_group_gate();
BEGIN
  IF _user = _me THEN RAISE EXCEPTION 'MSG-086: use leave to leave a group' USING ERRCODE = 'invalid_parameter_value'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.conversation_members m JOIN public.conversations c ON c.id = m.conversation_id
                  WHERE m.conversation_id = _conversation AND m.user_id = _me AND m.role = 'owner' AND c.kind = 'group') THEN
    RAISE EXCEPTION 'MSG-085: only the group owner can remove members' USING ERRCODE = 'insufficient_privilege';
  END IF;
  DELETE FROM public.conversation_members WHERE conversation_id = _conversation AND user_id = _user AND role <> 'owner';
  RETURN FOUND;
END
$fn$;

CREATE FUNCTION public.message_group_leave(_conversation uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _me uuid := auth.uid();
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'MSG-001: sign in' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF EXISTS (SELECT 1 FROM public.conversation_members m WHERE m.conversation_id = _conversation AND m.user_id = _me AND m.role = 'owner') THEN
    RAISE EXCEPTION 'MSG-086: the group owner cannot leave the group' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  DELETE FROM public.conversation_members m USING public.conversations c
   WHERE m.conversation_id = _conversation AND m.user_id = _me AND c.id = m.conversation_id AND c.kind = 'group';
  RETURN FOUND;
END
$fn$;

CREATE FUNCTION public.message_send_group(_conversation uuid, _body text, _client_msg_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me uuid := public.message_group_gate();
  _text text := btrim(coalesce(_body, ''));
  _rules public.message_member_rules%ROWTYPE;
  _admin boolean;
  _limit integer; _age_days numeric;
  _guard text; _status text := 'sent'; _msg bigint; _dup record;
BEGIN
  IF _client_msg_id IS NULL OR _text = '' OR char_length(_text) > 4000 THEN
    RAISE EXCEPTION 'MSG-003: a message needs 1–4000 characters and a message id' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.conversation_members m JOIN public.conversations c ON c.id = m.conversation_id
                  WHERE m.conversation_id = _conversation AND m.user_id = _me AND c.kind = 'group') THEN
    RAISE EXCEPTION 'MSG-071: not your group' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT m.id, m.conversation_id INTO _dup FROM public.messages m WHERE m.sender_id = _me AND m.client_msg_id = _client_msg_id;
  IF FOUND THEN RETURN jsonb_build_object('message_id', _dup.id, 'conversation_id', _dup.conversation_id, 'duplicate', true); END IF;
  _admin := public.has_role(_me, 'admin'::public.app_role);
  SELECT * INTO _rules FROM public.message_member_rules r WHERE r.user_id = _me;
  IF FOUND AND NOT _rules.text_ok THEN
    RAISE EXCEPTION 'MSG-021: text messages are not available for your account' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT _admin THEN
    IF (SELECT count(*) FROM public.messages m WHERE m.sender_id = _me AND m.created_at > now() - interval '1 minute') >= 20 THEN
      RAISE EXCEPTION 'MSG-050: slow down — too many messages in a minute' USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT extract(epoch FROM (now() - p.created_at)) / 86400 INTO _age_days FROM public.profiles p WHERE p.id = _me;
    _limit := coalesce(_rules.daily_limit, CASE WHEN coalesce(_age_days, 0) < 7 THEN 50 ELSE 500 END);
    IF (SELECT count(*) FROM public.messages m WHERE m.sender_id = _me AND m.created_at > now() - interval '24 hours') >= _limit THEN
      RAISE EXCEPTION 'MSG-051: daily message limit reached' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  _guard := public.message_word_guard(_me, _text);
  IF _guard = 'block' THEN RAISE EXCEPTION 'MSG-060: this message cannot be sent' USING ERRCODE = 'insufficient_privilege';
  ELSIF _guard = 'hold' THEN _status := 'held'; END IF;
  BEGIN
    INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id, status)
    VALUES (_conversation, _me, 'text', _text, _client_msg_id, _status) RETURNING id INTO _msg;
  EXCEPTION WHEN unique_violation THEN
    SELECT m.id, m.conversation_id INTO _dup FROM public.messages m WHERE m.sender_id = _me AND m.client_msg_id = _client_msg_id;
    RETURN jsonb_build_object('message_id', _dup.id, 'conversation_id', _dup.conversation_id, 'duplicate', true);
  END;
  IF _status = 'sent' THEN UPDATE public.conversations SET last_message_at = now() WHERE id = _conversation; END IF;
  IF _guard = 'hold' THEN INSERT INTO public.message_guard_events (user_id, action, message_id) VALUES (_me, 'hold', _msg); END IF;
  RETURN jsonb_build_object('message_id', _msg, 'conversation_id', _conversation, 'duplicate', false, 'status', _status, 'help', (_guard = 'help'));
END
$fn$;

REVOKE ALL ON FUNCTION public.message_group_gate() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_group_can_take(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_group_create(text, uuid[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_group_add(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_group_remove(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_group_leave(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_send_group(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_group_create(text, uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_group_add(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_group_remove(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_group_leave(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_send_group(uuid, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_group_gate(), public.message_group_can_take(uuid, uuid) TO service_role;

COMMIT;

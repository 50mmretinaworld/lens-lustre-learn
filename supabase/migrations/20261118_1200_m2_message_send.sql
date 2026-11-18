-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1200 · M2 — the ONE door for sending a private message
-- Needs M1 (20261118_1100). Direct (1:1) text only: photos = M5, groups = M6,
-- push = M3, admin switch functions = M2b, word-guard rules = M2c.
--
-- message_send(_to, _body, _client_msg_id) — SECURITY DEFINER, signed-in members.
-- The sender is ALWAYS auth.uid(); there is no sender argument to forge.
-- Checks, in this order, first failure wins (each has its own error code):
--   MSG-001 not signed in                    MSG-050 more than 20 messages in a minute
--   ACCOUNT_UNDER_REVIEW sender not allowed  MSG-051 daily limit reached
--   MSG-002 bad recipient (null / self)      MSG-052 too many new chats today
--   MSG-003 empty / too long / no message id MSG-060 word guard: blocked
--   MSG-010 messaging off for this sender    MSG-011 recipient cannot receive
--   MSG-020 timed block   MSG-021 text off   MSG-022 friends only
--   MSG-030 blocked either way               MSG-040 no follow / friend link
-- Same (sender, client_msg_id) twice → returns the first message, writes nothing.
-- Relationship: official (admin) account → anyone, inbox. Friend, or mutual
-- follow → inbox. Sender follows, receiver does not follow back → the
-- receiver's Requests folder. Anything else → refused.
-- Limits do not apply to the official (admin) account. New accounts (< 7 days)
-- get a lower daily limit. A member's own daily_limit (message_member_rules)
-- overrides it.
--
-- Also: message_control_allows(uid) — the 4-mode rule, internal; message_allowed_me()
-- — for the app to show / grey the button (the server refuses anyway);
-- message_word_guard(uid, body) — STUB returning 'ok' until M2c replaces it.
--
-- Rollback: supabase/rollback/20261118_1200_m2_message_send_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1200_m2_message_send.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.messages') IS NULL THEN
    RAISE EXCEPTION 'M2-PRE-001: M1 (20261118_1100) is not applied';
  END IF;
  IF to_regprocedure('public.message_send(uuid,text,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'M2-PRE-002: message_send already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. the 4-mode rule (internal) ──────────────────────────────────────────
CREATE FUNCTION public.message_control_allows(_uid uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN _uid IS NULL THEN false
              ELSE coalesce((SELECT CASE c.mode
                                      WHEN 'allowed_all'       THEN true
                                      WHEN 'allowed_selected'  THEN EXISTS (SELECT 1 FROM public.message_control_members m WHERE m.user_id = _uid)
                                      WHEN 'blocked_all'       THEN false
                                      WHEN 'blocked_selected'  THEN NOT EXISTS (SELECT 1 FROM public.message_control_members m WHERE m.user_id = _uid)
                                      ELSE false END
                               FROM public.message_control c), false)
         END;
$fn$;

CREATE FUNCTION public.message_allowed_me()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL
     AND public.account_can_act((SELECT auth.uid()))
     AND public.message_control_allows((SELECT auth.uid()))
     AND NOT coalesce((SELECT r.blocked_until > now() FROM public.message_member_rules r WHERE r.user_id = (SELECT auth.uid())), false);
$fn$;

-- ── 2. word guard (stub until M2c) ─────────────────────────────────────────
CREATE FUNCTION public.message_word_guard(_uid uuid, _body text)
RETURNS text                                  -- 'ok' | 'block' | 'hold' | 'help'
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT 'ok'::text; $fn$;

-- ── 3. the door ────────────────────────────────────────────────────────────
CREATE FUNCTION public.message_send(_to uuid, _body text, _client_msg_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me         uuid := auth.uid();
  _text       text := btrim(coalesce(_body, ''));
  _admin      boolean;
  _rules      public.message_member_rules%ROWTYPE;
  _friend     boolean;
  _follows    boolean;
  _followback boolean;
  _folder     text;
  _key        text;
  _conv       uuid;
  _new_conv   boolean := false;
  _guard      text;
  _status     text := 'sent';
  _msg        bigint;
  _dup        record;
  _limit      integer;
  _age_days   numeric;
BEGIN
  IF _me IS NULL THEN
    RAISE EXCEPTION 'MSG-001: sign in to send a message' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.account_can_act(_me) THEN
    RAISE EXCEPTION 'ACCOUNT_UNDER_REVIEW' USING ERRCODE = 'insufficient_privilege',
      DETAIL = 'Your account is under review', HINT = 'support@50mmretina.com';
  END IF;
  IF _to IS NULL OR _to = _me THEN
    RAISE EXCEPTION 'MSG-002: choose another member to message' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _client_msg_id IS NULL OR _text = '' OR char_length(_text) > 4000 THEN
    RAISE EXCEPTION 'MSG-003: a message needs 1–4000 characters and a message id' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- same message never twice
  SELECT m.id, m.conversation_id INTO _dup FROM public.messages m WHERE m.sender_id = _me AND m.client_msg_id = _client_msg_id;
  IF FOUND THEN
    RETURN jsonb_build_object('message_id', _dup.id, 'conversation_id', _dup.conversation_id, 'duplicate', true);
  END IF;

  -- admin switch (4 modes) and this member's own rules
  IF NOT public.message_control_allows(_me) THEN
    RAISE EXCEPTION 'MSG-010: messaging is not available for your account' USING ERRCODE = 'insufficient_privilege';
  END IF;
  _admin := public.has_role(_me, 'admin'::public.app_role);
  SELECT * INTO _rules FROM public.message_member_rules r WHERE r.user_id = _me;
  IF FOUND THEN
    IF _rules.blocked_until IS NOT NULL AND _rules.blocked_until > now() THEN
      RAISE EXCEPTION 'MSG-020: messaging is paused for your account until %', to_char(_rules.blocked_until, 'YYYY-MM-DD')
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT _rules.text_ok THEN
      RAISE EXCEPTION 'MSG-021: text messages are not available for your account' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- recipient: must exist and be able to receive; blocks either way
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = _to) OR NOT public.account_can_act(_to) THEN
    RAISE EXCEPTION 'MSG-011: this member cannot receive messages' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF EXISTS (SELECT 1 FROM public.user_blocks b
              WHERE (b.blocker_id = _me AND b.blocked_id = _to) OR (b.blocker_id = _to AND b.blocked_id = _me)) THEN
    RAISE EXCEPTION 'MSG-030: you cannot message this member' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- relationship → folder
  _friend := EXISTS (SELECT 1 FROM public.friendships f WHERE f.status = 'accepted'
                      AND ((f.requester_id = _me AND f.addressee_id = _to) OR (f.requester_id = _to AND f.addressee_id = _me)));
  _follows    := EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = _me AND f.following_id = _to);
  _followback := EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = _to AND f.following_id = _me);
  IF coalesce(_rules.friends_only, false) AND NOT (_friend OR _admin) THEN
    RAISE EXCEPTION 'MSG-022: your account can message friends only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _admin OR _friend OR (_follows AND _followback) THEN
    _folder := 'inbox';
  ELSIF _follows THEN
    _folder := 'requests';
  ELSE
    RAISE EXCEPTION 'MSG-040: you can message members you follow and your friends' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- limits (not for the official account)
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

  -- word guard
  _guard := public.message_word_guard(_me, _text);
  IF _guard = 'block' THEN
    RAISE EXCEPTION 'MSG-060: this message cannot be sent' USING ERRCODE = 'insufficient_privilege';
  ELSIF _guard = 'hold' THEN
    _status := 'held';
  END IF;

  -- the chat (one per pair)
  _key := least(_me::text, _to::text) || ':' || greatest(_me::text, _to::text);
  SELECT c.id INTO _conv FROM public.conversations c WHERE c.direct_key = _key;
  IF _conv IS NULL THEN
    IF NOT _admin AND (SELECT count(*) FROM public.conversations c WHERE c.created_by = _me AND c.created_at > now() - interval '24 hours') >= 30 THEN
      RAISE EXCEPTION 'MSG-052: too many new chats today' USING ERRCODE = 'insufficient_privilege';
    END IF;
    INSERT INTO public.conversations (kind, direct_key, created_by) VALUES ('direct', _key, _me)
    ON CONFLICT (direct_key) DO NOTHING RETURNING id INTO _conv;
    IF _conv IS NULL THEN
      SELECT c.id INTO _conv FROM public.conversations c WHERE c.direct_key = _key;
    ELSE
      _new_conv := true;
    END IF;
    INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conv, _me, 'owner', 'inbox') ON CONFLICT DO NOTHING;
    INSERT INTO public.conversation_members (conversation_id, user_id, role, folder) VALUES (_conv, _to, 'member', _folder) ON CONFLICT DO NOTHING;
  ELSIF _folder = 'inbox' THEN
    -- they became friends / follow each other since the last message: move out of Requests (never out of 'declined' by the sender)
    UPDATE public.conversation_members SET folder = 'inbox' WHERE conversation_id = _conv AND user_id = _to AND folder = 'requests';
  END IF;

  BEGIN
    INSERT INTO public.messages (conversation_id, sender_id, kind, body, client_msg_id, status)
    VALUES (_conv, _me, 'text', _text, _client_msg_id, _status) RETURNING id INTO _msg;
  EXCEPTION WHEN unique_violation THEN
    SELECT m.id, m.conversation_id INTO _dup FROM public.messages m WHERE m.sender_id = _me AND m.client_msg_id = _client_msg_id;
    RETURN jsonb_build_object('message_id', _dup.id, 'conversation_id', _dup.conversation_id, 'duplicate', true);
  END;
  IF _status = 'sent' THEN
    UPDATE public.conversations SET last_message_at = now() WHERE id = _conv;
  END IF;
  IF _guard = 'hold' THEN
    INSERT INTO public.message_guard_events (user_id, action, message_id) VALUES (_me, 'hold', _msg);
  END IF;

  RETURN jsonb_build_object('message_id', _msg, 'conversation_id', _conv, 'duplicate', false,
                            'status', _status, 'folder', _folder, 'new_chat', _new_conv);
END
$fn$;

-- ── 4. rights ──────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.message_control_allows(uuid)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_word_guard(uuid, text)    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_allowed_me()              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_send(uuid, text, uuid)    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_control_allows(uuid)   TO service_role;
GRANT EXECUTE ON FUNCTION public.message_word_guard(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.message_allowed_me()           TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_send(uuid, text, uuid) TO authenticated, service_role;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1400 · M2c — the word guard (replaces the M2 stub)
-- Needs M1 + M2 + M2b. Owner decisions 15 Nov 2026: block abusive, political and
-- abnormal words (threats, suicide, murder, antisocial acts and similar). Actions:
--   block → the message is refused (MSG-060), nothing is stored;
--   hold  → stored with status 'held', NOT delivered, waits for admin review;
--   help  → delivered; the sender is shown a helpline (message_send returns
--           help = true) and an admin is alerted (no message text in the alert).
-- Strictest hit wins: block > hold > help.
--
-- Matching: a rule written in plain ASCII matches whole words, case-insensitive;
-- a rule in any other script (Bengali, Hindi …) matches as a phrase inside the text.
-- Rules are plain phrases, never regular expressions (admin typos cannot hang the server).
--
-- A SMALL STARTER English list is seeded (all active) so the guard can be tested; the
-- Owner / lawyer own the real list (incl. Bengali / Hindi) and edit it in the admin page.
-- Words only ever come from admin functions below; every change is reasoned + logged.
--
-- message_send is re-issued here only to return the help flag; every other line is
-- identical to M2.
--
-- Rollback: supabase/rollback/20261118_1400_m2c_word_guard_ROLLBACK.sql (restores the stub)
-- PROBE:    supabase/migrations/PROBE_20261118_1400_m2c_word_guard.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_admin_check(text)') IS NULL THEN
    RAISE EXCEPTION 'M2C-PRE-001: M2b (20261118_1300) is not applied';
  END IF;
  IF to_regprocedure('public.message_admin_word_add(text,text,text,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'M2C-PRE-002: word guard already installed — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. starter list ────────────────────────────────────────────────────────
INSERT INTO public.message_word_rules (category, pattern, lang, action) VALUES
  ('threat',    'kill you',        'en', 'block'),
  ('threat',    'i will kill',     'en', 'block'),
  ('threat',    'murder you',      'en', 'block'),
  ('abuse',     'bastard',         'en', 'block'),
  ('abuse',     'bitch',           'en', 'block'),
  ('abuse',     'whore',           'en', 'block'),
  ('abuse',     'motherfucker',    'en', 'block'),
  ('political', 'vote for',        'en', 'hold'),
  ('political', 'election',        'en', 'hold'),
  ('political', 'bjp',             'en', 'hold'),
  ('political', 'congress party',  'en', 'hold'),
  ('abnormal',  'send nudes',      'en', 'hold'),
  ('self_harm', 'suicide',         'en', 'help'),
  ('self_harm', 'kill myself',     'en', 'help'),
  ('self_harm', 'end my life',     'en', 'help'),
  ('self_harm', 'want to die',     'en', 'help');

-- ── 2. the guard (volatile: it records a 'help' hit and alerts an admin) ──
DROP FUNCTION public.message_word_guard(uuid, text);
CREATE FUNCTION public.message_word_guard(_uid uuid, _body text)
RETURNS text                                  -- 'ok' | 'block' | 'hold' | 'help'
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _hit record;
  _txt text := lower(coalesce(_body, ''));
BEGIN
  SELECT r.id, r.action INTO _hit
    FROM public.message_word_rules r
   WHERE r.active
     AND CASE WHEN r.pattern ~ '^[\x20-\x7E]+$'
              THEN _txt ~ ('\m' || regexp_replace(lower(r.pattern), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
              ELSE position(lower(r.pattern) in _txt) > 0 END
   ORDER BY array_position(ARRAY['block', 'hold', 'help'], r.action), r.id
   LIMIT 1;
  IF NOT FOUND THEN RETURN 'ok'; END IF;
  IF _hit.action = 'help' THEN
    INSERT INTO public.message_guard_events (user_id, rule_id, action) VALUES (_uid, _hit.id, 'help');
    INSERT INTO public.admin_notifications (type, title, message, reference_id)
    VALUES ('message_help', 'A member may need help',
            'The messages word guard flagged a self-harm phrase from user ' || _uid::text || '. Please review and reach out. (No message text is attached.)',
            _uid);
  END IF;
  RETURN _hit.action;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_word_guard(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_word_guard(uuid, text) TO service_role;

-- ── 3. admin: add / switch a word rule (reason + log) ─────────────────────
CREATE FUNCTION public.message_admin_word_add(_category text, _pattern text, _lang text, _action text, _reason text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _id bigint; _p text := btrim(coalesce(_pattern, ''));
BEGIN
  IF _category NOT IN ('abuse', 'threat', 'political', 'self_harm', 'abnormal') OR _action NOT IN ('block', 'hold', 'help') THEN
    RAISE EXCEPTION 'MSGADM-006: bad category or action' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF char_length(_p) < 2 OR char_length(_p) > 200 THEN
    RAISE EXCEPTION 'MSGADM-006: a word or phrase of 2–200 characters is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  INSERT INTO public.message_word_rules (category, pattern, lang, action, added_by)
  VALUES (_category, _p, nullif(btrim(coalesce(_lang, '')), ''), _action, _uid) RETURNING id INTO _id;
  INSERT INTO public.message_control_log (actor_id, area, old_value, new_value, reason)
  VALUES (_uid, 'word_rule', NULL, format('add #%s %s/%s "%s"', _id, _category, _action, left(_p, 60)), btrim(_reason));
  RETURN _id;
END
$fn$;

CREATE FUNCTION public.message_admin_word_set_active(_id bigint, _active boolean, _reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _old boolean;
BEGIN
  SELECT active INTO _old FROM public.message_word_rules WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MSGADM-007: no such word rule' USING ERRCODE = 'no_data_found'; END IF;
  IF _old = _active THEN RETURN _active; END IF;
  UPDATE public.message_word_rules SET active = _active WHERE id = _id;
  INSERT INTO public.message_control_log (actor_id, area, old_value, new_value, reason)
  VALUES (_uid, 'word_rule', format('#%s active=%s', _id, _old), format('#%s active=%s', _id, _active), btrim(_reason));
  RETURN _active;
END
$fn$;

REVOKE ALL ON FUNCTION public.message_admin_word_add(text, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_word_set_active(bigint, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_admin_word_add(text, text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_word_set_active(bigint, boolean, text) TO authenticated, service_role;

-- ── 4. message_send re-issued: identical to M2 except the 'help' flag in the answer ──
CREATE OR REPLACE FUNCTION public.message_send(_to uuid, _body text, _client_msg_id uuid)
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

  SELECT m.id, m.conversation_id INTO _dup FROM public.messages m WHERE m.sender_id = _me AND m.client_msg_id = _client_msg_id;
  IF FOUND THEN
    RETURN jsonb_build_object('message_id', _dup.id, 'conversation_id', _dup.conversation_id, 'duplicate', true);
  END IF;

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

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = _to) OR NOT public.account_can_act(_to) THEN
    RAISE EXCEPTION 'MSG-011: this member cannot receive messages' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF EXISTS (SELECT 1 FROM public.user_blocks b
              WHERE (b.blocker_id = _me AND b.blocked_id = _to) OR (b.blocker_id = _to AND b.blocked_id = _me)) THEN
    RAISE EXCEPTION 'MSG-030: you cannot message this member' USING ERRCODE = 'insufficient_privilege';
  END IF;

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
  IF _guard = 'block' THEN
    RAISE EXCEPTION 'MSG-060: this message cannot be sent' USING ERRCODE = 'insufficient_privilege';
  ELSIF _guard = 'hold' THEN
    _status := 'held';
  END IF;

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
                            'status', _status, 'folder', _folder, 'new_chat', _new_conv, 'help', (_guard = 'help'));
END
$fn$;

COMMIT;

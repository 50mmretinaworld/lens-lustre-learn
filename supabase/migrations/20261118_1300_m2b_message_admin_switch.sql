-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1300 · M2b — admin switch for messages (4 modes + per-member rules)
-- Needs M1 + M2. Owner decisions 15 Nov 2026: Allowed all / Allowed selected /
-- Blocked all / Blocked selected; per-member text / photos / groups / friends-only /
-- daily limit; timed block with an end date; every change records reason + who/when;
-- enforced in the server send check, instant, no app release. Member search reuses
-- the shared feature_member_search() (one search for every admin switch).
--
-- Every function: admin only (server re-check), reason REQUIRED, one append-only
-- row in message_control_log. Nothing is written by the app directly.
--   message_admin_set_mode(mode, reason)
--   message_admin_set_groups(on, reason)
--   message_admin_list_add(user, reason) / message_admin_list_remove(user, reason)
--   message_admin_set_member_rule(user, text_ok, photos_ok, groups_ok, friends_only,
--                                 daily_limit, blocked_until, reason)
--   message_admin_clear_member_rule(user, reason)
--   message_admin_state()  — one read for the admin page (mode, list, rules, last 50 log rows)
--
-- Rollback: supabase/rollback/20261118_1300_m2b_message_admin_switch_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1300_m2b_message_admin_switch.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_send(uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'M2B-PRE-001: M2 (20261118_1200) is not applied';
  END IF;
  IF to_regprocedure('public.message_admin_set_mode(text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'M2B-PRE-002: message_admin_set_mode already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- the one admin + reason check every function starts with
CREATE FUNCTION public.message_admin_check(_reason text)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can change the messages switch' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(btrim(_reason), '') = '' OR char_length(_reason) > 500 THEN
    RAISE EXCEPTION 'MSGADM-002: a reason (1–500 characters) is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN _uid;
END
$fn$;

CREATE FUNCTION public.message_admin_set_mode(_mode text, _reason text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _old text;
BEGIN
  IF _mode IS NULL OR _mode NOT IN ('allowed_all', 'allowed_selected', 'blocked_all', 'blocked_selected') THEN
    RAISE EXCEPTION 'MSGADM-003: mode must be allowed_all, allowed_selected, blocked_all or blocked_selected' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT mode INTO _old FROM public.message_control FOR UPDATE;
  IF _old = _mode THEN RETURN _mode; END IF;
  UPDATE public.message_control SET mode = _mode, note = left(_reason, 500), updated_by = _uid, updated_at = now();
  INSERT INTO public.message_control_log (actor_id, area, old_value, new_value, reason) VALUES (_uid, 'mode', _old, _mode, btrim(_reason));
  RETURN _mode;
END
$fn$;

CREATE FUNCTION public.message_admin_set_groups(_on boolean, _reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _old boolean;
BEGIN
  IF _on IS NULL THEN RAISE EXCEPTION 'MSGADM-003: on / off required' USING ERRCODE = 'invalid_parameter_value'; END IF;
  SELECT groups_enabled INTO _old FROM public.message_control FOR UPDATE;
  IF _old = _on THEN RETURN _on; END IF;
  UPDATE public.message_control SET groups_enabled = _on, updated_by = _uid, updated_at = now();
  INSERT INTO public.message_control_log (actor_id, area, old_value, new_value, reason) VALUES (_uid, 'groups', _old::text, _on::text, btrim(_reason));
  RETURN _on;
END
$fn$;

CREATE FUNCTION public.message_admin_list_add(_user uuid, _reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason);
BEGIN
  IF _user IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = _user) THEN
    RAISE EXCEPTION 'MSGADM-004: no such member' USING ERRCODE = 'no_data_found';
  END IF;
  INSERT INTO public.message_control_members (user_id, listed_by, note) VALUES (_user, _uid, left(_reason, 500)) ON CONFLICT (user_id) DO NOTHING;
  IF NOT FOUND THEN RETURN false; END IF;
  INSERT INTO public.message_control_log (actor_id, area, user_id, old_value, new_value, reason) VALUES (_uid, 'list', _user, 'not listed', 'listed', btrim(_reason));
  RETURN true;
END
$fn$;

CREATE FUNCTION public.message_admin_list_remove(_user uuid, _reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason);
BEGIN
  DELETE FROM public.message_control_members WHERE user_id = _user;
  IF NOT FOUND THEN RETURN false; END IF;
  INSERT INTO public.message_control_log (actor_id, area, user_id, old_value, new_value, reason) VALUES (_uid, 'list', _user, 'listed', 'not listed', btrim(_reason));
  RETURN true;
END
$fn$;

CREATE FUNCTION public.message_admin_set_member_rule(
  _user uuid, _text_ok boolean, _photos_ok boolean, _groups_ok boolean, _friends_only boolean,
  _daily_limit integer, _blocked_until timestamptz, _reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _old public.message_member_rules%ROWTYPE;
BEGIN
  IF _user IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = _user) THEN
    RAISE EXCEPTION 'MSGADM-004: no such member' USING ERRCODE = 'no_data_found';
  END IF;
  IF _daily_limit IS NOT NULL AND (_daily_limit < 0 OR _daily_limit > 100000) THEN
    RAISE EXCEPTION 'MSGADM-005: daily limit must be 0–100000' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO _old FROM public.message_member_rules WHERE user_id = _user;
  INSERT INTO public.message_member_rules (user_id, text_ok, photos_ok, groups_ok, friends_only, daily_limit, blocked_until, reason, set_by, set_at)
  VALUES (_user, coalesce(_text_ok, true), coalesce(_photos_ok, true), coalesce(_groups_ok, true), coalesce(_friends_only, false),
          _daily_limit, _blocked_until, left(btrim(_reason), 500), _uid, now())
  ON CONFLICT (user_id) DO UPDATE
     SET text_ok = EXCLUDED.text_ok, photos_ok = EXCLUDED.photos_ok, groups_ok = EXCLUDED.groups_ok,
         friends_only = EXCLUDED.friends_only, daily_limit = EXCLUDED.daily_limit, blocked_until = EXCLUDED.blocked_until,
         reason = EXCLUDED.reason, set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at;
  INSERT INTO public.message_control_log (actor_id, area, user_id, old_value, new_value, reason)
  VALUES (_uid, 'member_rule', _user,
          CASE WHEN _old.user_id IS NULL THEN 'default' ELSE format('text=%s photos=%s groups=%s friends_only=%s limit=%s until=%s',
               _old.text_ok, _old.photos_ok, _old.groups_ok, _old.friends_only, coalesce(_old.daily_limit::text, '-'), coalesce(_old.blocked_until::text, '-')) END,
          format('text=%s photos=%s groups=%s friends_only=%s limit=%s until=%s',
               coalesce(_text_ok, true), coalesce(_photos_ok, true), coalesce(_groups_ok, true), coalesce(_friends_only, false),
               coalesce(_daily_limit::text, '-'), coalesce(_blocked_until::text, '-')),
          btrim(_reason));
  RETURN true;
END
$fn$;

CREATE FUNCTION public.message_admin_clear_member_rule(_user uuid, _reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason);
BEGIN
  DELETE FROM public.message_member_rules WHERE user_id = _user;
  IF NOT FOUND THEN RETURN false; END IF;
  INSERT INTO public.message_control_log (actor_id, area, user_id, old_value, new_value, reason) VALUES (_uid, 'member_rule', _user, 'custom', 'default', btrim(_reason));
  RETURN true;
END
$fn$;

-- one read for the admin page
CREATE FUNCTION public.message_admin_state()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can read the messages switch' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN jsonb_build_object(
    'mode', (SELECT c.mode FROM public.message_control c),
    'groups_enabled', (SELECT c.groups_enabled FROM public.message_control c),
    'updated_at', (SELECT c.updated_at FROM public.message_control c),
    'members', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', m.user_id, 'full_name', p.full_name, 'username', p.custom_url,
                                                            'avatar_url', p.avatar_url, 'listed_at', m.listed_at, 'note', m.note) ORDER BY m.listed_at)
                           FROM public.message_control_members m LEFT JOIN public.profiles p ON p.id = m.user_id), '[]'::jsonb),
    'rules', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', r.user_id, 'full_name', p.full_name, 'text_ok', r.text_ok, 'photos_ok', r.photos_ok,
                                                          'groups_ok', r.groups_ok, 'friends_only', r.friends_only, 'daily_limit', r.daily_limit,
                                                          'blocked_until', r.blocked_until, 'reason', r.reason, 'set_at', r.set_at) ORDER BY r.set_at DESC)
                         FROM public.message_member_rules r LEFT JOIN public.profiles p ON p.id = r.user_id), '[]'::jsonb),
    'log', coalesce((SELECT jsonb_agg(l ORDER BY l->>'at' DESC) FROM (
                       SELECT jsonb_build_object('at', g.at, 'actor', g.actor_id, 'area', g.area, 'user_id', g.user_id,
                                                 'old', g.old_value, 'new', g.new_value, 'reason', g.reason) AS l
                         FROM public.message_control_log g ORDER BY g.at DESC LIMIT 50) x), '[]'::jsonb));
END
$fn$;

REVOKE ALL ON FUNCTION public.message_admin_check(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_admin_set_mode(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_set_groups(boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_list_add(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_list_remove(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_set_member_rule(uuid, boolean, boolean, boolean, boolean, integer, timestamptz, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_clear_member_rule(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_admin_set_mode(text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_set_groups(boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_list_add(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_list_remove(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_set_member_rule(uuid, boolean, boolean, boolean, boolean, integer, timestamptz, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_clear_member_rule(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_state() TO authenticated, service_role;

COMMIT;

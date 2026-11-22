-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_4000 · M31 — one DEFAULT RULE for messaging, set by the admin, with "apply to everyone" (Owner 22 Nov 2026)
--
--  Owner: "Admin will set the default rule. If the default rule is updated, give an 'apply to everyone' option so it is effective
--  for everyone at once. Example: default = chat only → every member gets chat only; later photos allowed + apply → every old
--  member gets photos at one go." And: the daily limits (500 a day; 50 a day in the first 7 days) were fixed in code with no
--  admin control.
--
--  1. message_default_rules — ONE row: text / photos / groups / friends-only, and the two daily limits
--     (daily_limit for members older than 7 days, new_daily_limit for the first 7 days). Seeded with today's behaviour
--     (all on, friends-only off, 500 and 50), so applying this changes nothing for members until the admin saves a new default.
--  2. message_effective_rule(member) — the member's own rule if the admin set one, otherwise the default. Every messaging
--     check that read message_member_rules for the acting member (send, photos, groups, "may I message", reach checks) now reads
--     this instead — patched in place, the original definitions are kept in message_m31_backup for the rollback.
--     A member's own daily limit still wins; without one, the default limits apply (patched in the send function).
--  3. admin_message_default_get() / message_admin_set_default(…, _apply, _reason) — admin only, reason required, logged.
--     Save            → at once for every member who has no rule of their own (and every new member).
--     Save + _apply   → also replaces every member's own rule with the default; a member's PAUSE date is kept.
--
--  The two fixed safety limits stay as they are: 20 messages a minute and 30 new chats a day.
--
-- Rollback: supabase/rollback/20261118_4000_m31_default_rule_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_4000_m31_default_rule.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.message_default_rules') IS NOT NULL THEN
    RAISE EXCEPTION 'M31-PRE-001: message_default_rules already exists — not re-applying';
  END IF;
  IF to_regclass('public.message_member_rules') IS NULL THEN
    RAISE EXCEPTION 'M31-PRE-002: message_member_rules missing';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. the default rule ────────────────────────────────────────────────────
CREATE TABLE public.message_default_rules (
  id               boolean PRIMARY KEY DEFAULT true CHECK (id),          -- one row only
  text_ok          boolean NOT NULL DEFAULT true,
  photos_ok        boolean NOT NULL DEFAULT true,
  groups_ok        boolean NOT NULL DEFAULT true,
  friends_only     boolean NOT NULL DEFAULT false,
  daily_limit      integer NOT NULL DEFAULT 500 CHECK (daily_limit BETWEEN 0 AND 100000),
  new_daily_limit  integer NOT NULL DEFAULT 50  CHECK (new_daily_limit BETWEEN 0 AND 100000),
  updated_by       uuid,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.message_default_rules (id) VALUES (true);
ALTER TABLE public.message_default_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_default_rules FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_default_rules TO service_role;

CREATE TABLE public.message_m31_backup (
  fn   text PRIMARY KEY,
  def  text NOT NULL
);
ALTER TABLE public.message_m31_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_m31_backup FROM PUBLIC, anon, authenticated;

-- ── 2. the effective rule of one member ────────────────────────────────────
CREATE FUNCTION public.message_effective_rule(_u uuid)
RETURNS SETOF public.message_member_rules
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT r.* FROM public.message_member_rules r WHERE r.user_id = _u
  UNION ALL
  SELECT _u, d.text_ok, d.photos_ok, d.groups_ok, d.friends_only, NULL::integer, NULL::timestamptz, NULL::text, NULL::uuid, d.updated_at
    FROM public.message_default_rules d
   WHERE NOT EXISTS (SELECT 1 FROM public.message_member_rules r2 WHERE r2.user_id = _u);
$fn$;
-- Only called from inside the (definer) messaging checks, which run as the function owner — members cannot call it
-- directly, so nobody can look up another member's rule.
REVOKE ALL ON FUNCTION public.message_effective_rule(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_effective_rule(uuid) TO service_role;

-- ── 2b. every messaging check reads the effective rule ─────────────────────
DO $patch$
DECLARE
  rec record; _def text; _new text; _n int := 0; _lim int := 0; _names text[] := '{}';
  _read constant text := '(?<!DELETE )FROM public\.message_member_rules( [a-z_]+)? WHERE (?:[a-z_]+\.)?user_id = (_[a-z_]+|\(SELECT auth\.uid\(\)\))';
  _limit_old constant text := 'CASE WHEN coalesce(_age_days, 0) < 7 THEN 50 ELSE 500 END';
  _limit_new constant text := '(SELECT CASE WHEN coalesce(_age_days, 0) < 7 THEN dr.new_daily_limit ELSE dr.daily_limit END FROM public.message_default_rules dr)';
BEGIN
  FOR rec IN
    SELECT p.oid, p.oid::regprocedure::text AS sig, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND p.proname <> 'message_effective_rule'
       AND p.proname NOT LIKE 'message\_admin\_%' AND p.proname NOT LIKE 'admin\_%'
       AND (p.prosrc ~ _read OR position(_limit_old IN p.prosrc) > 0)
  LOOP
    _def := pg_get_functiondef(rec.oid);
    INSERT INTO public.message_m31_backup (fn, def) VALUES (rec.sig, _def);
    _new := regexp_replace(_def, _read, 'FROM public.message_effective_rule(\2)\1 WHERE true', 'g');
    IF position(_limit_old IN _new) > 0 THEN
      _new := replace(_new, _limit_old, _limit_new);
      _lim := _lim + 1;
    END IF;
    EXECUTE _new;
    _n := _n + 1;
    _names := _names || rec.proname::text;
  END LOOP;
  IF _n = 0 THEN RAISE EXCEPTION 'M31-PRE-003: no messaging check reads message_member_rules — nothing to patch'; END IF;
  IF _lim = 0 THEN RAISE EXCEPTION 'M31-PRE-004: the daily-limit line (50 / 500) was not found in any function'; END IF;
  RAISE NOTICE 'M31 patched % function(s) (daily limit in %): %', _n, _lim, array_to_string(_names, ', ');
END
$patch$;

-- ── 3. admin: read / save / apply ──────────────────────────────────────────
CREATE FUNCTION public.admin_message_default_get()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can read the default rule' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN (SELECT jsonb_build_object(
            'text_ok', d.text_ok, 'photos_ok', d.photos_ok, 'groups_ok', d.groups_ok, 'friends_only', d.friends_only,
            'daily_limit', d.daily_limit, 'new_daily_limit', d.new_daily_limit, 'updated_at', d.updated_at,
            'own_rules', (SELECT count(*) FROM public.message_member_rules),
            'paused', (SELECT count(*) FROM public.message_member_rules r WHERE r.blocked_until > now()))
            FROM public.message_default_rules d);
END
$fn$;

CREATE FUNCTION public.message_admin_set_default(
  _text_ok boolean, _photos_ok boolean, _groups_ok boolean, _friends_only boolean,
  _daily_limit integer, _new_daily_limit integer, _apply boolean, _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := public.message_admin_check(_reason);
  _old public.message_default_rules;
  _replaced integer := 0;
  _fmt text;
BEGIN
  IF _daily_limit IS NULL OR _daily_limit < 0 OR _daily_limit > 100000 OR _new_daily_limit IS NULL OR _new_daily_limit < 0 OR _new_daily_limit > 100000 THEN
    RAISE EXCEPTION 'MSGADM-005: daily limits must be whole numbers from 0 to 100000' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO _old FROM public.message_default_rules WHERE id FOR UPDATE;
  UPDATE public.message_default_rules
     SET text_ok = coalesce(_text_ok, true), photos_ok = coalesce(_photos_ok, true), groups_ok = coalesce(_groups_ok, true),
         friends_only = coalesce(_friends_only, false), daily_limit = _daily_limit, new_daily_limit = _new_daily_limit,
         updated_by = _uid, updated_at = now()
   WHERE id;
  IF coalesce(_apply, false) THEN
    UPDATE public.message_member_rules
       SET text_ok = coalesce(_text_ok, true), photos_ok = coalesce(_photos_ok, true), groups_ok = coalesce(_groups_ok, true),
           friends_only = coalesce(_friends_only, false), daily_limit = NULL,
           reason = left('Default rule applied to everyone: ' || btrim(_reason), 500), set_by = _uid, set_at = now()
     WHERE user_id IS NOT NULL;
    GET DIAGNOSTICS _replaced = ROW_COUNT;
    -- a row that is now the same as the default and carries no running pause is not needed any more
    DELETE FROM public.message_member_rules WHERE blocked_until IS NULL OR blocked_until <= now();
  END IF;
  _fmt := 'default text=%s photos=%s groups=%s friends_only=%s limit=%s new_member_limit=%s';
  INSERT INTO public.message_control_log (actor_id, area, user_id, old_value, new_value, reason)
  VALUES (_uid, 'member_rule', NULL,
          format(_fmt, _old.text_ok, _old.photos_ok, _old.groups_ok, _old.friends_only, _old.daily_limit, _old.new_daily_limit),
          format(_fmt, coalesce(_text_ok, true), coalesce(_photos_ok, true), coalesce(_groups_ok, true), coalesce(_friends_only, false), _daily_limit, _new_daily_limit)
            || CASE WHEN coalesce(_apply, false) THEN format(' · applied to everyone (%s own rules replaced)', _replaced) ELSE '' END,
          btrim(_reason));
  RETURN jsonb_build_object('applied', coalesce(_apply, false), 'replaced', _replaced);
END
$fn$;

REVOKE ALL ON FUNCTION public.admin_message_default_get() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_set_default(boolean, boolean, boolean, boolean, integer, integer, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_message_default_get() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_admin_set_default(boolean, boolean, boolean, boolean, integer, integer, boolean, text) TO authenticated, service_role;

COMMIT;

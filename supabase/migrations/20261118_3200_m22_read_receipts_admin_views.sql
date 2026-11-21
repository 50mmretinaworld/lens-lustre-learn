-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_3200 · M22 — "hide read receipts" + a quiet record of admin chat views (Owner 21 Nov 2026)
--
--  1. Read receipts off (like Meta). A member who sets profiles.privacy_settings->>'read_receipts' = 'off' is never shown to
--     the sender as having READ: the sender sees at most "delivered" (two grey ticks). message_tick is patched in place — one
--     condition added to its 'read' branch; every other tick rule stays as it is.
--  2. Admin chat views are written to their own small table message_admin_views (admin, chat, time), at most one row per
--     admin per chat per 10 minutes, first page of a thread only. No alarm reads it and no limit is applied (Owner: the
--     admin opens any member's box without limit). It exists so the site can truthfully say who opened which chat if a
--     legal request or a member complaint ever needs it. Only the service role can read or write it.
--
-- Rollback: supabase/rollback/20261118_3200_m22_read_receipts_admin_views_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_3200_m22_read_receipts_admin_views.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_can_reach(uuid)') IS NULL THEN
    RAISE EXCEPTION 'M22-PRE-001: 20261118_2910 is not applied';
  END IF;
  IF to_regclass('public.message_admin_views') IS NOT NULL THEN
    RAISE EXCEPTION 'M22-PRE-002: message_admin_views already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. read receipts ───────────────────────────────────────────────────────
DO $patch$
DECLARE
  _def text := pg_get_functiondef('public.message_tick(uuid,uuid,timestamptz)'::regprocedure);
  _old constant text := 'WHEN bool_and(coalesce(cm.last_read_at, ''-infinity''::timestamptz) >= _created) THEN ''read''';
  _new constant text := 'WHEN bool_and(coalesce(cm.last_read_at, ''-infinity''::timestamptz) >= _created)
         AND NOT bool_or(coalesce((SELECT p.privacy_settings ->> ''read_receipts'' FROM public.profiles p WHERE p.id = cm.user_id), ''on'') = ''off'') THEN ''read''';
BEGIN
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'M22-PRE-003: the read branch of message_tick was not found — nothing patched'; END IF;
  EXECUTE replace(_def, _old, _new);
END
$patch$;

-- ── 2. who opened which chat (admin viewer) ────────────────────────────────
CREATE TABLE public.message_admin_views (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  admin_id         uuid NOT NULL,
  member_id        uuid NOT NULL,
  conversation_id  uuid NOT NULL,
  at               timestamptz NOT NULL DEFAULT now()
);
-- P28: message_admin_views · at most one row per admin per chat per 10 minutes · the dedupe look-up and "who opened this chat"
CREATE INDEX message_admin_views_lookup_idx ON public.message_admin_views (admin_id, conversation_id, at DESC);
ALTER TABLE public.message_admin_views ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_admin_views FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.message_admin_views TO service_role;

DO $patch$
DECLARE
  _def text := pg_get_functiondef('public.admin_view_thread(uuid,uuid,bigint,integer)'::regprocedure);
  _old constant text := 'RETURN coalesce((';
  _new constant text := 'IF _before_id IS NULL AND NOT EXISTS (SELECT 1 FROM public.message_admin_views v WHERE v.admin_id = _uid AND v.conversation_id = _conversation AND v.at > now() - interval ''10 minutes'') THEN
    INSERT INTO public.message_admin_views (admin_id, member_id, conversation_id) VALUES (_uid, _user, _conversation);
  END IF;
  RETURN coalesce((';
BEGIN
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'M22-PRE-004: the return of admin_view_thread was not found — nothing patched'; END IF;
  -- the function now writes a row, so it can no longer be declared STABLE
  EXECUTE replace(replace(_def, 'STABLE SECURITY DEFINER', 'SECURITY DEFINER'), _old, _new);
END
$patch$;

COMMIT;

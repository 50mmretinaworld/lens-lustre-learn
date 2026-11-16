-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261116_1500 push centre PN1. Removes everything 1500 added.
-- Loses the send history, drafts, templates and permission answers recorded
-- since — the old one-box send page keeps working (send-broadcast-push keeps
-- its title/body path).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED — p32.lane is not asserted. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regclass('public.push_broadcasts') IS NULL THEN
    RAISE EXCEPTION 'PC-1500-RB-PRE-001: 1500 is not applied — nothing to roll back';
  END IF;
END
$pre$;

-- scheduled sends that have not run: cancel, then drop the kind's rows
UPDATE public.jobs SET status = 'cancelled', finished_at = now(), updated_at = now()
 WHERE kind = 'push.broadcast' AND status IN ('queued', 'running');
DELETE FROM public.jobs WHERE kind = 'push.broadcast';
DELETE FROM public.job_kinds WHERE kind = 'push.broadcast';

DROP FUNCTION public.admin_push_audience(jsonb);
DROP FUNCTION public.admin_push_broadcast_save(bigint, jsonb);
DROP FUNCTION public.admin_push_broadcast_schedule(bigint, timestamptz);
DROP FUNCTION public.admin_push_broadcast_cancel(bigint);
DROP FUNCTION public.admin_push_broadcast_delete(bigint);
DROP FUNCTION public.admin_push_broadcasts(text, integer, integer);
DROP FUNCTION public.push_broadcast_claim(bigint);
DROP FUNCTION public.push_broadcast_finish(bigint, jsonb);
DROP FUNCTION public.push_broadcast_targets(bigint, bigint, integer);
DROP FUNCTION public.register_push_device(text, text, text, text[]);
DROP FUNCTION public.report_push_permission(text, text, text);
DROP FUNCTION public.push_audience_members(jsonb);
DROP FUNCTION public.push_audience_check(jsonb);

DROP TRIGGER trg_push_broadcast_count_open ON public.notification_deliveries;
DROP FUNCTION public.push_broadcast_count_open();
ALTER TABLE public.notification_deliveries DROP COLUMN broadcast_id;
DROP TABLE public.push_broadcasts;
DROP TABLE public.push_permission_state;
ALTER TABLE public.push_tokens DROP COLUMN app_version, DROP COLUMN caps;

DO $post$
BEGIN
  IF to_regclass('public.push_broadcasts') IS NOT NULL OR to_regclass('public.push_permission_state') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN (
          'admin_push_audience', 'admin_push_broadcast_save', 'admin_push_broadcast_schedule',
          'admin_push_broadcast_cancel', 'admin_push_broadcast_delete', 'admin_push_broadcasts',
          'push_broadcast_claim', 'push_broadcast_finish', 'push_broadcast_targets', 'register_push_device', 'report_push_permission',
          'push_audience_members', 'push_audience_check', 'push_broadcast_count_open'))
     OR EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.broadcast') THEN
    RAISE EXCEPTION 'PC-1500-RB-POST-001: a 1500 object is still present';
  END IF;
  IF to_regprocedure('public.register_push_token(text, text)') IS NULL THEN
    RAISE EXCEPTION 'PC-1500-RB-POST-002: register_push_token is missing — old app builds could not register';
  END IF;
END
$post$;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_3100 · M19 — chat photos live 30 days on the server (Owner approved 21 Nov 2026, "like WhatsApp")
--
--  * message_attachments.expired_at — set when the file has been deleted from storage after 30 days. The message and its
--    text stay for ever; only the picture goes. The thread (member + admin viewer) reports `expired` per photo; the app shows
--    "Photo no longer available" unless this device still holds its own copy.
--  * message_photos_due(limit) / message_photos_mark_expired(ids) — service role only. A SQL job cannot delete a storage file,
--    so the daily job `message.photo_purge` calls the edge function message-photo-purge, which asks for the due photos, deletes
--    the files through the Storage API and only THEN marks them expired. A file that failed to delete is tried again next day.
--  * message_maintenance (the daily job that already exists) now also queues that purge job once a day.
--
-- Rollback: supabase/rollback/20261118_3100_m19_photo_retention_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_3100_m19_photo_retention.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_maintenance(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'M19-PRE-001: M7 (20261118_1800) is not applied';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'message_attachments' AND column_name = 'expired_at') THEN
    RAISE EXCEPTION 'M19-PRE-002: message_attachments.expired_at already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. the mark ────────────────────────────────────────────────────────────
ALTER TABLE public.message_attachments ADD COLUMN expired_at timestamptz;
-- P28: message_attachments · only unexpired rows older than 30 days are ever looked up (the daily purge)
CREATE INDEX message_attachments_due_idx ON public.message_attachments (created_at) WHERE expired_at IS NULL;

-- ── 2. the thread tells the app which photos are gone (member view + admin viewer) ──
DO $patch$
DECLARE
  _f text; _def text;
  _old constant text := '''height'', a.height)';
  _new constant text := '''height'', a.height, ''expired'', (a.expired_at IS NOT NULL))';
BEGIN
  FOREACH _f IN ARRAY ARRAY['public.message_thread(uuid,bigint,integer)', 'public.admin_view_thread(uuid,uuid,bigint,integer)'] LOOP
    _def := pg_get_functiondef(_f::regprocedure);
    IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'M19-PRE-003: the photo list of % was not found — nothing patched', _f; END IF;
    EXECUTE replace(_def, _old, _new);
  END LOOP;
END
$patch$;

-- ── 3. the purge's two doors (service role only) ───────────────────────────
CREATE FUNCTION public.message_photos_due(_limit integer DEFAULT 200)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'path', x.storage_path)), '[]'::jsonb)
    FROM (SELECT a.id, a.storage_path FROM public.message_attachments a
           WHERE a.expired_at IS NULL AND a.created_at < now() - interval '30 days'
           ORDER BY a.created_at LIMIT least(greatest(coalesce(_limit, 200), 1), 500)) x;
$fn$;
REVOKE ALL ON FUNCTION public.message_photos_due(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_photos_due(integer) TO service_role;

CREATE FUNCTION public.message_photos_mark_expired(_ids uuid[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _n integer;
BEGIN
  UPDATE public.message_attachments a SET expired_at = now()
   WHERE a.id = ANY (coalesce(_ids, '{}'::uuid[])) AND a.expired_at IS NULL AND a.created_at < now() - interval '30 days';
  GET DIAGNOSTICS _n = ROW_COUNT;
  RETURN _n;
END
$fn$;
REVOKE ALL ON FUNCTION public.message_photos_mark_expired(uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_photos_mark_expired(uuid[]) TO service_role;

-- ── 4. the job: one purge a day, queued by the daily maintenance ───────────
INSERT INTO public.job_kinds (kind, handler, max_attempts, backoff_seconds, timeout_seconds, max_running, extra_headers_secret, note)
VALUES ('message.photo_purge', 'edge:message-photo-purge', 3, ARRAY[300, 1800], 300, 1, 'jobs:edge:send-push',
        'M19: daily (key photo-purge:<date>); deletes chat photos older than 30 days from storage, then marks them expired');

DO $patch$
DECLARE
  _def text := pg_get_functiondef('public.message_maintenance(jsonb)'::regprocedure);
  _old constant text := 'PERFORM public.message_logs_trim();';
  _new constant text := 'PERFORM public.message_logs_trim();
  PERFORM public.job_enqueue(''message.photo_purge'', ''{}''::jsonb, ''photo-purge:'' || to_char(now() AT TIME ZONE ''UTC'', ''YYYY-MM-DD''));';
BEGIN
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'M19-PRE-004: message_maintenance was not found in the expected shape — nothing patched'; END IF;
  EXECUTE replace(_def, _old, _new);
END
$patch$;

-- the first purge: tomorrow's maintenance would queue it; queue today's too (idempotent key)
SELECT public.job_enqueue('message.photo_purge', '{}'::jsonb, 'photo-purge:' || to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD'));

COMMIT;

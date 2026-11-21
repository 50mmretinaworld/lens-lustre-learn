-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3101 — is the daily chat-photo purge really running? READ-ONLY (changes nothing).
-- Prints the last jobs of kind message.photo_purge and how many chat photos are still due. Ends "PURGE PASS" when the
-- newest job is done, or when none is due yet; "PURGE FAIL" when the newest job failed or has been queued for over 1 hour
-- while the job engine is on.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  r record; _newest record; _due int; _expired int; _engine boolean;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'PURGE lane %', current_setting('p32.lane', true);
  SELECT coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false) INTO _engine;
  FOR r IN SELECT id, status, attempts, run_at, finished_at, left(coalesce(last_error, ''), 160) AS err FROM public.jobs WHERE kind = 'message.photo_purge' ORDER BY id DESC LIMIT 5 LOOP
    RAISE NOTICE 'job % status=% attempts=% run_at=% finished=% err=%', r.id, r.status, r.attempts, r.run_at, r.finished_at, r.err;
  END LOOP;
  SELECT count(*) INTO _due FROM public.message_attachments WHERE expired_at IS NULL AND created_at < now() - interval '30 days';
  SELECT count(*) INTO _expired FROM public.message_attachments WHERE expired_at IS NOT NULL;
  RAISE NOTICE 'job engine on: %  |  photos still due: %  |  photos expired so far: %', _engine, _due, _expired;
  SELECT id, status, run_at INTO _newest FROM public.jobs WHERE kind = 'message.photo_purge' ORDER BY id DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURGE FAIL: no message.photo_purge job exists'; END IF;
  IF _newest.status = 'failed' THEN RAISE EXCEPTION 'PURGE FAIL: the newest purge job failed (job %)', _newest.id; END IF;
  IF _engine AND _newest.status = 'queued' AND _newest.run_at < now() - interval '1 hour' THEN
    RAISE EXCEPTION 'PURGE FAIL: the newest purge job (%) has been queued for over an hour', _newest.id;
  END IF;
  RAISE NOTICE 'PURGE PASS — newest job % is %', _newest.id, _newest.status;
END
$p$;

ROLLBACK;

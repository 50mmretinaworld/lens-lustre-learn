-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261116_1501 — READ-ONLY report: did the 23 min with the account guard
-- ON on live (16 Nov 11:41–12:04 UTC) leave any video or photo stuck?
--   V1  video uploads since 11:00 UTC by status; any with an ACCOUNT_UNDER_REVIEW error
--   V2  uploads not finished (queued / converting / failed) since 11:00, oldest age
--   V3  converter account: last seen
--   P1  photo blur: codes made since 12:00 UTC (the worker writes again)
-- Fails only when an upload since 11:00 carries an ACCOUNT_UNDER_REVIEW error.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
DO $p$
DECLARE r record; _bad int; _since timestamptz := '2026-11-16 11:00:00+00';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'GW lane %', current_setting('p32.lane', true);
  FOR r IN SELECT status, count(*) n, round(extract(epoch FROM now() - min(created_at)) / 60) oldest_min
             FROM public.video_sources WHERE created_at >= _since GROUP BY status ORDER BY status LOOP
    RAISE NOTICE 'GW V1 video uploads since 11:00 | % | n=% | oldest_min=%', r.status, r.n, r.oldest_min;
  END LOOP;
  SELECT count(*) INTO _bad FROM public.video_sources WHERE created_at >= _since AND error ILIKE '%ACCOUNT_UNDER_REVIEW%';
  RAISE NOTICE 'GW V1 uploads with ACCOUNT_UNDER_REVIEW error = %', _bad;
  FOR r IN SELECT id, status, attempts, round(extract(epoch FROM now() - created_at) / 60) age_min, left(coalesce(error, '-'), 120) err
             FROM public.video_sources
            WHERE created_at >= _since AND status IN ('queued', 'converting', 'failed') ORDER BY created_at LOOP
    RAISE NOTICE 'GW V2 not finished | % | % | tries=% | age_min=% | %', r.id, r.status, r.attempts, r.age_min, r.err;
  END LOOP;
  FOR r IN SELECT last_seen_at FROM public.video_converter_accounts LOOP
    RAISE NOTICE 'GW V3 converter last seen %', r.last_seen_at;
  END LOOP;
  RAISE NOTICE 'GW P1 blur codes made since 12:00 = %', (SELECT count(*) FROM public.photo_blur WHERE made_at >= '2026-11-16 12:00:00+00');
  IF _bad > 0 THEN RAISE EXCEPTION 'GW FAIL — % video upload(s) refused by the guard', _bad; END IF;
  RAISE NOTICE 'GW DONE';
END
$p$;
ROLLBACK;

-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBE · 20261128_7100 honour "Share my honour" e-mail. WRITES NOTHING (everything ends in ROLLBACK).
-- FAILS before apply (B1 looks for the share=honour link in the function).
--   B1  structure: DEFINER, search_path=public, trigger still on user_badges, allow-list unchanged, 7100 body.
--   B2  'verified' → ONE bell row "You've been honoured" with email_sent = true (no second generic e-mail), and ONE
--       honour e-mail logged (email_send_log, notification-alert) when the member has a deliverable address.
--   B3  'elite_member' → the honour words "… as an Elite Member."
--   B4  any other badge → 'New Badge!' unchanged, and no honour e-mail.
-- Prints counts only; no member id, no address, no content.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';

DO $p$
DECLARE
  _m      uuid;
  _admin  uuid;
  _other  text;
  _bid    uuid;
  _title  text;
  _msg    text;
  _sent   boolean;
  _n      integer;
  _logs0  bigint;
  _logs1  bigint;
  _want   integer;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  -- B1 ── structure ──────────────────────────────────────────────────────────────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.notify_badge_awarded()'::regprocedure
                    AND prosecdef AND proconfig @> ARRAY['search_path=public']) THEN
    RAISE EXCEPTION 'PROBE FAIL B1: notify_badge_awarded not DEFINER with search_path=public';
  END IF;
  IF position('share=honour' IN pg_get_functiondef('public.notify_badge_awarded()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'PROBE FAIL B1: notify_badge_awarded has no honour e-mail (7100 not applied)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notify_badge_awarded'
                    AND tgrelid = 'public.user_badges'::regclass AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'PROBE FAIL B1: trg_notify_badge_awarded missing';
  END IF;
  IF to_regclass('public.notification_writer_allowlist') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.notification_writer_allowlist WHERE fn_name = 'notify_badge_awarded') THEN
    RAISE EXCEPTION 'PROBE FAIL B1: notify_badge_awarded dropped off notification_writer_allowlist';
  END IF;

  SELECT p.id INTO _m
    FROM public.profiles p
   WHERE NOT EXISTS (SELECT 1 FROM public.user_badges b WHERE b.user_id = p.id AND b.badge_type IN ('verified', 'elite_member'))
     AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id)
   ORDER BY p.last_active_at DESC NULLS LAST
   LIMIT 1;
  IF _m IS NULL THEN RAISE EXCEPTION 'PROBE FAIL: no member without an honour to test with'; END IF;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role = 'admin' ORDER BY r.user_id LIMIT 1;
  IF _admin IS NULL THEN RAISE EXCEPTION 'PROBE FAIL: no admin to stand as assigned_by'; END IF;

  SELECT CASE WHEN u.email IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.suppressed_emails s WHERE s.email = lower(u.email))
              THEN 1 ELSE 0 END INTO _want
    FROM auth.users u WHERE u.id = _m;
  _want := coalesce(_want, 0);

  -- B2 ── verified → bell row + one e-mail ────────────────────────────────────────────────────────────────────────
  SELECT count(*) INTO _logs0 FROM public.email_send_log;
  INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, 'verified', _admin) RETURNING id INTO _bid;
  SELECT count(*) INTO _logs1 FROM public.email_send_log;
  SELECT count(*) INTO _n FROM public.user_notifications WHERE reference_id = _bid AND type = 'badge_awarded';
  IF _n <> 1 THEN RAISE EXCEPTION 'PROBE FAIL B2: % bell rows for one verified badge (want 1)', _n; END IF;
  SELECT title, email_sent INTO _title, _sent FROM public.user_notifications WHERE reference_id = _bid AND type = 'badge_awarded';
  IF _title IS DISTINCT FROM 'You''ve been honoured' THEN RAISE EXCEPTION 'PROBE FAIL B2: wrong title'; END IF;
  IF _sent IS NOT TRUE THEN RAISE EXCEPTION 'PROBE FAIL B2: email_sent not true (a second generic e-mail could go)'; END IF;
  IF _logs1 - _logs0 <> _want THEN
    RAISE EXCEPTION 'PROBE FAIL B2: % honour e-mails logged (want %)', _logs1 - _logs0, _want;
  END IF;

  -- B3 ── elite_member → honour words ────────────────────────────────────────────────────────────────────────────
  INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, 'elite_member', _admin) RETURNING id INTO _bid;
  SELECT title, message INTO _title, _msg FROM public.user_notifications WHERE reference_id = _bid AND type = 'badge_awarded';
  IF _title IS DISTINCT FROM 'You''ve been honoured' OR _msg NOT LIKE '%as an Elite Member.' THEN
    RAISE EXCEPTION 'PROBE FAIL B3: elite_member lacks the honour words';
  END IF;

  -- B4 ── any other badge → unchanged, no e-mail ─────────────────────────────────────────────────────────────────
  SELECT d.type_key INTO _other
    FROM public.badge_definitions d
   WHERE d.type_key NOT IN ('verified', 'elite_member')
     AND NOT EXISTS (SELECT 1 FROM public.user_badges b WHERE b.user_id = _m AND b.badge_type = d.type_key)
   ORDER BY d.type_key LIMIT 1;
  IF _other IS NULL THEN
    RAISE NOTICE 'PROBE B4 skipped: no other badge type free for the test member';
  ELSE
    SELECT count(*) INTO _logs0 FROM public.email_send_log;
    INSERT INTO public.user_badges (user_id, badge_type, assigned_by) VALUES (_m, _other, _admin) RETURNING id INTO _bid;
    SELECT count(*) INTO _logs1 FROM public.email_send_log;
    SELECT title, message INTO _title, _msg FROM public.user_notifications WHERE reference_id = _bid AND type = 'badge_awarded';
    IF _title IS DISTINCT FROM 'New Badge!' OR _msg NOT LIKE 'You''ve been awarded the "%" badge! 🏅' THEN
      RAISE EXCEPTION 'PROBE FAIL B4: other badges lost their wording';
    END IF;
    IF _logs1 <> _logs0 THEN RAISE EXCEPTION 'PROBE FAIL B4: an ordinary badge queued an honour e-mail'; END IF;
  END IF;

  RAISE NOTICE 'PROBE PASS 7100: B1 structure, B2 bell + % e-mail, B3 elite words, B4 %.',
    _want, CASE WHEN _other IS NULL THEN 'skipped' ELSE 'other badges unchanged' END;
END
$p$;

ROLLBACK;

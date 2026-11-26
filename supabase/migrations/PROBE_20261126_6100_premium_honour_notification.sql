-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBE · 20261126_6100 premium honour notification. WRITES NOTHING (everything ends in ROLLBACK). FAILS before apply.
--   B1  structure: notify_badge_awarded is SECURITY DEFINER, search_path=public, still fired by
--       trg_notify_badge_awarded (AFTER INSERT on user_badges), still on notification_writer_allowlist.
--   B2  giving 'verified' to a member who lacks it writes ONE 'badge_awarded' notification titled
--       "You've been honoured" with the approved message.
--   B3  giving any OTHER badge still writes 'New Badge!' with the old wording.
-- Prints counts only; no member id, no content.
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';

DO $p$
DECLARE
  _m      uuid;   -- a member without the verified badge
  _other  text;   -- a badge type that member does not hold, not 'verified'
  _bid    uuid;
  _title  text;
  _msg    text;
  _n      integer;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  -- B1 ── structure ──────────────────────────────────────────────────────────────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.notify_badge_awarded()'::regprocedure
                    AND prosecdef AND proconfig @> ARRAY['search_path=public']) THEN
    RAISE EXCEPTION 'PROBE FAIL B1: notify_badge_awarded not DEFINER with search_path=public';
  END IF;
  IF position('You''''ve been honoured' IN pg_get_functiondef('public.notify_badge_awarded()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'PROBE FAIL B1: notify_badge_awarded has no honour wording (6100 not applied)';
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
   WHERE NOT EXISTS (SELECT 1 FROM public.user_badges b WHERE b.user_id = p.id AND b.badge_type = 'verified')
   ORDER BY p.created_at
   LIMIT 1;
  IF _m IS NULL THEN RAISE EXCEPTION 'PROBE FAIL: no member without the verified badge to test with'; END IF;

  -- B2 ── verified → the honour words ───────────────────────────────────────────────────────────────────────────
  INSERT INTO public.user_badges (user_id, badge_type) VALUES (_m, 'verified') RETURNING id INTO _bid;
  SELECT count(*) INTO _n FROM public.user_notifications WHERE reference_id = _bid AND type = 'badge_awarded';
  IF _n <> 1 THEN RAISE EXCEPTION 'PROBE FAIL B2: % notifications for one verified badge (want 1)', _n; END IF;
  SELECT title, message INTO _title, _msg FROM public.user_notifications WHERE reference_id = _bid AND type = 'badge_awarded';
  IF _title IS DISTINCT FROM 'You''ve been honoured' THEN RAISE EXCEPTION 'PROBE FAIL B2: wrong title'; END IF;
  IF _msg IS DISTINCT FROM
     'The 50mm Retina World curators have honoured you as a Premium Member. Choose your Featured photo to show on your card.' THEN
    RAISE EXCEPTION 'PROBE FAIL B2: wrong message';
  END IF;

  -- B3 ── any other badge → unchanged words ─────────────────────────────────────────────────────────────────────
  SELECT d.type_key INTO _other
    FROM public.badge_definitions d
   WHERE d.type_key <> 'verified'
     AND NOT EXISTS (SELECT 1 FROM public.user_badges b WHERE b.user_id = _m AND b.badge_type = d.type_key)
   ORDER BY d.type_key
   LIMIT 1;
  IF _other IS NULL THEN
    RAISE NOTICE 'PROBE B3 skipped: no other badge type free for the test member';
  ELSE
    INSERT INTO public.user_badges (user_id, badge_type) VALUES (_m, _other) RETURNING id INTO _bid;
    SELECT title, message INTO _title, _msg FROM public.user_notifications WHERE reference_id = _bid AND type = 'badge_awarded';
    IF _title IS DISTINCT FROM 'New Badge!' OR _msg NOT LIKE 'You''ve been awarded the "%" badge! 🏅' THEN
      RAISE EXCEPTION 'PROBE FAIL B3: other badges lost their wording';
    END IF;
  END IF;

  RAISE NOTICE 'PROBE PASS 6100: B1 structure, B2 honour wording, B3 other badges unchanged (%).',
    CASE WHEN _other IS NULL THEN 'B3 skipped' ELSE 'B3 run' END;
END
$p$;

ROLLBACK;

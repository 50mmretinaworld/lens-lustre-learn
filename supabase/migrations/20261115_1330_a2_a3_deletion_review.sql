-- ═══════════════════════════════════════════════════════════════════════════
-- 20261115_1330 · A2 + A3 — deletion requests wait for admin review; ONE delete program
-- Owner decisions 15 Nov 2026:
--   · admin deletes a member → everything is wiped at once, no copy kept;
--     only the log row (who, when, reason) stays;
--   · a member's own delete request → admin approval; the admin may hold it
--     under review for unlimited time; with no hold it is approved
--     automatically after 180 days;
--   · while waiting / under review the member can log in but do nothing (A1 guard).
-- Today: delete-my-account and delete-user are two copies of one hard-delete
-- program (edge code), and a member's tap deletes at once.
--
-- This file (database side; the two edge functions call it from A3b):
--   account_delete_execute(uid, actor, reason) — THE delete program: auth user
--       first (cascades), then every non-cascading table both edge copies
--       cleared, the orphan purge, a log row, and the erasure e-mail as a job.
--   admin_delete_member(uid, reason)       — admin only, reason required, instant.
--   request_my_account_deletion()          — member: request, no deletion;
--       state deletion_requested, auto_approve_at = now + 180 days (an account
--       already under review keeps its hold: no automatic approval).
--   admin_decide_deletion(uid, approve|hold, reason) — admin: approve = delete
--       now; hold = under review, unlimited, auto-approval removed.
--   account_deletion_sweep(payload)        — daily job: due requests → one
--       account.delete job each (one failure never blocks the rest), then
--       schedules itself for tomorrow 03:00 UTC.
--   admin_list_account_reviews(), admin_account_state_history(uid) — admin page (A2).
-- Job kinds: account.deletion_sweep, account.delete, email.account_deleted.
-- Rollback: supabase/rollback/20261115_1330_a2_a3_deletion_review_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261115_1330_a2_a3_deletion_review.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regclass('public.account_states') IS NULL OR to_regprocedure('public.job_start(bigint)') IS NULL THEN
    RAISE EXCEPTION 'A2-PRE-001: A1 (20261115_1310) and J3b (20261115_1230) must be applied first';
  END IF;
  IF to_regprocedure('public.admin_delete_auth_user(uuid)') IS NULL OR to_regprocedure('public.admin_purge_orphan_user_data(uuid)') IS NULL THEN
    RAISE EXCEPTION 'A2-PRE-002: admin_delete_auth_user / admin_purge_orphan_user_data missing';
  END IF;
  IF to_regprocedure('public.account_delete_execute(uuid,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'A2-PRE-003: already applied';
  END IF;
END
$lane_guard$;

-- log rows may now record the final step
ALTER TABLE public.account_state_log
  ADD CONSTRAINT account_state_log_to_state_chk
  CHECK (to_state IN ('active', 'under_review', 'deletion_requested', 'deleted')) NOT VALID;

-- ── 1. THE delete program ──────────────────────────────────────────────────
CREATE FUNCTION public.account_delete_execute(_uid uuid, _actor uuid, _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _email text;
  _name text;
  _from text;
  _gone boolean;
  t text;
  _purge jsonb;
  _user_id_tables text[] := ARRAY[
    'activity_logs', 'bank_details', 'certificate_testimonials', 'certificates',
    'comment_reactions', 'comments', 'competition_entries', 'competition_votes',
    'course_enrollments', 'featured_photos', 'gift_announcements', 'highlights',
    'image_comments', 'image_reactions', 'lesson_progress', 'post_comment_reactions',
    'post_comments', 'post_reactions', 'posts', 'referral_codes', 'role_applications',
    'stories', 'support_tickets', 'ticket_replies', 'user_badges', 'user_notifications',
    'user_roles', 'verification_requests', 'wallet_transactions', 'wallets',
    'withdrawal_requests', 'user_devices', 'scheduled_posts', 'post_shares', 'photo_albums',
    'notification_preferences', 'newsletter_subscribers'];
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'account_delete_execute: no member' USING ERRCODE = 'invalid_parameter_value'; END IF;
  SELECT u.email INTO _email FROM auth.users u WHERE u.id = _uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('deleted', false, 'reason', 'not found'); END IF;
  SELECT p.full_name INTO _name FROM public.profiles p WHERE p.id = _uid;
  SELECT coalesce((SELECT s.state FROM public.account_states s WHERE s.user_id = _uid), 'active') INTO _from;

  -- auth user FIRST (proven path; cascades the FK-linked tables, aborts cleanly)
  _gone := public.admin_delete_auth_user(_uid);
  IF _gone IS DISTINCT FROM true THEN
    RETURN jsonb_build_object('deleted', false, 'reason', 'auth user not deleted');
  END IF;

  FOREACH t IN ARRAY _user_id_tables LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DELETE FROM public.%I WHERE user_id = $1', t) USING _uid;
    END IF;
  END LOOP;
  DELETE FROM public.follows      WHERE follower_id = _uid OR following_id = _uid;
  DELETE FROM public.friendships  WHERE requester_id = _uid OR addressee_id = _uid;
  DELETE FROM public.profile_views WHERE profile_id = _uid OR viewer_id = _uid;
  DELETE FROM public.referrals    WHERE referrer_id = _uid OR referred_id = _uid;
  DELETE FROM public.competition_judges    WHERE judge_id = _uid;
  DELETE FROM public.judge_comments        WHERE judge_id = _uid;
  DELETE FROM public.judge_scores          WHERE judge_id = _uid;
  DELETE FROM public.judge_tag_assignments WHERE judge_id = _uid;
  DELETE FROM public.portfolio_images      WHERE uploaded_by = _uid;
  DELETE FROM public.reports         WHERE reporter_id = _uid;
  DELETE FROM public.comment_reports WHERE reporter_id = _uid;
  DELETE FROM public.post_reports    WHERE reporter_id = _uid;
  UPDATE public.comment_reports  SET reviewed_by = NULL WHERE reviewed_by = _uid;
  UPDATE public.post_reports     SET reviewed_by = NULL WHERE reviewed_by = _uid;
  UPDATE public.role_applications SET reviewed_by = NULL WHERE reviewed_by = _uid;
  IF to_regclass('public.verification_requests') IS NOT NULL THEN
    UPDATE public.verification_requests SET reviewed_by = NULL WHERE reviewed_by = _uid;
  END IF;
  UPDATE public.withdrawal_requests SET reviewed_by = NULL WHERE reviewed_by = _uid;
  -- actor_id on other members' notifications is kept on purpose (Owner option C,
  -- 2026-08-10: the display says "A deleted account").
  _purge := to_jsonb(public.admin_purge_orphan_user_data(_uid));
  DELETE FROM public.profiles WHERE id = _uid;   -- defensive no-op (cascaded)

  INSERT INTO public.account_state_log (user_id, from_state, to_state, reason, actor_id)
  VALUES (_uid, _from, 'deleted', left(coalesce(_reason, 'deleted'), 500), _actor);

  IF _email IS NOT NULL THEN
    PERFORM public.job_start(public.job_enqueue('email.account_deleted', jsonb_build_object(
      'templateName', 'account-deleted', 'recipientEmail', _email,
      'idempotencyKey', 'account-deleted-' || _uid::text,
      'templateData', jsonb_build_object('fullName', _name, 'deletedAt', now())),
      'account-deleted:' || _uid::text));
  END IF;
  RETURN jsonb_build_object('deleted', true, 'confirmation_email_queued', _email IS NOT NULL);
END
$fn$;

-- ── 2. admin: delete now ───────────────────────────────────────────────────
CREATE FUNCTION public.admin_delete_member(_user_id uuid, _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _actor uuid := auth.uid();
BEGIN
  IF _actor IS NULL OR NOT public.has_role(_actor, 'admin') THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _user_id = _actor THEN RAISE EXCEPTION 'Cannot delete yourself' USING ERRCODE = 'invalid_parameter_value'; END IF;
  IF coalesce(btrim(_reason), '') = '' THEN RAISE EXCEPTION 'a reason is required' USING ERRCODE = 'invalid_parameter_value'; END IF;
  RETURN public.account_delete_execute(_user_id, _actor, _reason);
END
$fn$;

-- ── 3. member: ask to be deleted (no deletion here) ────────────────────────
CREATE FUNCTION public.request_my_account_deletion()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _me uuid := auth.uid();
  s public.account_states;
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'sign in first' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF public.has_role(_me, 'admin') THEN
    RAISE EXCEPTION 'Admin accounts cannot be self-deleted. Please contact support.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO s FROM public.account_states WHERE user_id = _me FOR UPDATE;
  IF FOUND AND s.deletion_requested_at IS NOT NULL THEN
    RETURN 'already_requested';
  END IF;
  IF FOUND AND s.state = 'under_review' THEN
    -- an admin hold stays a hold: the request is recorded, no automatic approval
    UPDATE public.account_states SET deletion_requested_at = now() WHERE user_id = _me;
    INSERT INTO public.account_state_log (user_id, from_state, to_state, reason, actor_id)
    VALUES (_me, 'under_review', 'under_review', 'member asked to delete the account (held)', _me);
    RETURN 'under_review';
  END IF;
  INSERT INTO public.account_states (user_id, state, reason, set_by, set_at, deletion_requested_at, auto_approve_at)
  VALUES (_me, 'deletion_requested', 'member asked to delete the account', _me, now(), now(), now() + interval '180 days')
  ON CONFLICT (user_id) DO UPDATE SET state = 'deletion_requested', reason = EXCLUDED.reason, set_by = _me,
    set_at = now(), deletion_requested_at = now(), auto_approve_at = now() + interval '180 days';
  INSERT INTO public.account_state_log (user_id, from_state, to_state, reason, actor_id)
  VALUES (_me, 'active', 'deletion_requested', 'member asked to delete the account', _me);
  RETURN 'deletion_requested';
END
$fn$;

-- ── 4. admin: approve or hold a request ────────────────────────────────────
CREATE FUNCTION public.admin_decide_deletion(_user_id uuid, _decision text, _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _actor uuid := auth.uid();
  s public.account_states;
BEGIN
  IF _actor IS NULL OR NOT public.has_role(_actor, 'admin') THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF _decision NOT IN ('approve', 'hold') THEN RAISE EXCEPTION 'decision must be approve or hold' USING ERRCODE = 'invalid_parameter_value'; END IF;
  IF coalesce(btrim(_reason), '') = '' THEN RAISE EXCEPTION 'a reason is required' USING ERRCODE = 'invalid_parameter_value'; END IF;
  SELECT * INTO s FROM public.account_states WHERE user_id = _user_id FOR UPDATE;
  IF NOT FOUND OR s.deletion_requested_at IS NULL THEN
    RAISE EXCEPTION 'this member has not asked to be deleted' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF _decision = 'approve' THEN
    RETURN public.account_delete_execute(_user_id, _actor, 'deletion request approved: ' || _reason);
  END IF;
  UPDATE public.account_states SET state = 'under_review', reason = left(_reason, 500), set_by = _actor,
         set_at = now(), auto_approve_at = NULL WHERE user_id = _user_id;
  INSERT INTO public.account_state_log (user_id, from_state, to_state, reason, actor_id)
  VALUES (_user_id, s.state, 'under_review', left('deletion request held: ' || _reason, 500), _actor);
  RETURN jsonb_build_object('held', true);
END
$fn$;

-- ── 5. jobs: per-member delete + the daily sweep ───────────────────────────
CREATE FUNCTION public.account_delete_job(_p jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE s public.account_states;
BEGIN
  SELECT * INTO s FROM public.account_states WHERE user_id = (_p->>'user_id')::uuid;
  -- re-checked at run time: an admin hold placed after the job was queued wins
  IF NOT FOUND OR s.state <> 'deletion_requested' OR s.auto_approve_at IS NULL OR s.auto_approve_at > now() THEN
    RETURN;
  END IF;
  PERFORM public.account_delete_execute(s.user_id, NULL, 'deletion request auto-approved after 180 days');
END
$fn$;

CREATE FUNCTION public.account_deletion_sweep(_p jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record; _next timestamptz;
BEGIN
  FOR r IN SELECT user_id FROM public.account_states
            WHERE state = 'deletion_requested' AND auto_approve_at IS NOT NULL AND auto_approve_at <= now() LOOP
    PERFORM public.job_enqueue('account.delete', jsonb_build_object('user_id', r.user_id), 'account.delete:' || r.user_id::text);
  END LOOP;
  _next := date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + interval '1 day 3 hours';
  PERFORM public.job_enqueue('account.deletion_sweep', '{}'::jsonb, 'sweep:' || to_char(_next, 'YYYY-MM-DD'), _next);
END
$fn$;

-- ── 6. admin review page data ──────────────────────────────────────────────
CREATE FUNCTION public.admin_list_account_reviews()
RETURNS TABLE (user_id uuid, full_name text, state text, reason text, set_at timestamptz,
               set_by_name text, deletion_requested_at timestamptz, auto_approve_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
  SELECT s.user_id, p.full_name, s.state, s.reason, s.set_at, a.full_name, s.deletion_requested_at, s.auto_approve_at
    FROM public.account_states s
    LEFT JOIN public.profiles p ON p.id = s.user_id
    LEFT JOIN public.profiles a ON a.id = s.set_by
   ORDER BY s.set_at DESC;
END
$fn$;

CREATE FUNCTION public.admin_account_state_history(_user_id uuid)
RETURNS TABLE (created_at timestamptz, from_state text, to_state text, reason text, actor_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
  SELECT l.created_at, l.from_state, l.to_state, l.reason, p.full_name
    FROM public.account_state_log l LEFT JOIN public.profiles p ON p.id = l.actor_id
   WHERE l.user_id = _user_id ORDER BY l.created_at DESC, l.id DESC;
END
$fn$;

REVOKE ALL ON FUNCTION public.account_delete_execute(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_delete_member(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_my_account_deletion() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_decide_deletion(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.account_delete_job(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.account_deletion_sweep(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_list_account_reviews() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_account_state_history(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.account_delete_execute(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_member(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_my_account_deletion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_decide_deletion(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_account_reviews() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_account_state_history(uuid) TO authenticated;

-- ── 7. job kinds + the first sweep ─────────────────────────────────────────
INSERT INTO public.job_kinds (kind, handler, max_attempts, backoff_seconds, timeout_seconds, max_running, note) VALUES
  ('account.deletion_sweep', 'sql:public.account_deletion_sweep', 4, ARRAY[60, 300, 1800], 120, 1,
   'A2: daily, schedules itself; due deletion requests -> one account.delete job each'),
  ('account.delete', 'sql:public.account_delete_job', 4, ARRAY[60, 300, 1800], 300, 2,
   'A2: auto-approved deletion of one member (re-checks the hold at run time)'),
  ('email.account_deleted', 'edge:send-transactional-email', 4, ARRAY[60, 300, 1800], 60, 5,
   'A3: erasure-confirmation e-mail after a deletion');
SELECT public.job_enqueue('account.deletion_sweep', '{}'::jsonb,
         'sweep:' || to_char(date_trunc('day', now() AT TIME ZONE 'UTC') + interval '1 day', 'YYYY-MM-DD'),
         date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + interval '1 day 3 hours');

COMMIT;

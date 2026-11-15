-- ROLLBACK · 20261115_1331 · account_delete_execute exactly as 20261115_1330
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.account_delete_execute(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'A3c-PRE-001: 20261115_1330 is not applied on this lane';
  END IF;
END
$lane_guard$;

CREATE OR REPLACE FUNCTION public.account_delete_execute(_uid uuid, _actor uuid, _reason text)
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
REVOKE ALL ON FUNCTION public.account_delete_execute(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.account_delete_execute(uuid, uuid, text) TO service_role;

COMMIT;

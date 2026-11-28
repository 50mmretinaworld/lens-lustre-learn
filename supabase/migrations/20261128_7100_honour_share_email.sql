-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 20261128_7100 · "Share my honour" by E-MAIL (Owner bug list 28 Nov, item 6). Lanes: staging, production.
--
-- notify_badge_awarded() (last body: 20261126_6100) keeps every bell / push row it writes today, and adds:
--   • 'elite_member' gets the honour words too: "You've been honoured" / "… as an Elite Member."
--   • for 'verified' and 'elite_member' ONE e-mail to the member: the honour words and a "Share my honour" button
--     that opens https://www.50mmretina.com/<their handle>?share=honour (the profile opens the share sheet by
--     itself; no handle → /premium-members). Same queue, sender and layout as the first-post reminder
--     (20261102_0200): enqueue_email('transactional_emails', …), email_send_log row, unsubscribe token,
--     never to a suppressed address. idempotency_key 'honour-<user_badges.id>' = never twice for one honour.
--   • the bell row is written with email_sent = true so the generic send_notification_email() never adds a second
--     e-mail.
--   • the e-mail sits in its own sub-block: a queue error is logged and NEVER stops the admin giving the badge.
-- Every other badge keeps today's words ('New Badge!' / 'You've been awarded the "<label>" badge! 🏅').
-- Same SECURITY DEFINER, search_path 'public', trigger and allow-list name (CREATE OR REPLACE).
--
-- Rollback: supabase/rollback/20261128_7100_honour_share_email_ROLLBACK.sql (the 6100 body again)
-- PROBE:    supabase/migrations/PROBE_20261128_7100_honour_share_email.sql
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $pre$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
  IF to_regprocedure('public.enqueue_email(text, jsonb)') IS NULL THEN
    RAISE EXCEPTION 'HSE-7100-PRE-001: public.enqueue_email(text, jsonb) missing';
  END IF;
  IF to_regprocedure('public.notify_badge_awarded()') IS NULL THEN
    RAISE EXCEPTION 'HSE-7100-PRE-002: public.notify_badge_awarded() missing';
  END IF;
  IF to_regclass('public.email_send_log') IS NULL OR to_regclass('public.email_unsubscribe_tokens') IS NULL
     OR to_regclass('public.suppressed_emails') IS NULL THEN
    RAISE EXCEPTION 'HSE-7100-PRE-003: e-mail tables missing';
  END IF;
END
$pre$;

CREATE OR REPLACE FUNCTION public.notify_badge_awarded()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  _badge_label text;
  _msg   text;
  _title text := 'You''ve been honoured';
  _email text;
  _name  text;
  _handle text;
  _url   text;
  _token text;
  _mid   text;
  _html  text;
  _text  text;
BEGIN
  IF NEW.badge_type NOT IN ('verified', 'elite_member') THEN
    SELECT label INTO _badge_label FROM public.badge_definitions WHERE type_key = NEW.badge_type LIMIT 1;
    INSERT INTO public.user_notifications (user_id, actor_id, type, title, message, reference_id)
    VALUES (NEW.user_id, NEW.assigned_by, 'badge_awarded', 'New Badge!', 'You''ve been awarded the "' || COALESCE(_badge_label, NEW.badge_type) || '" badge! 🏅', NEW.id);
    RETURN NEW;
  END IF;

  _msg := CASE NEW.badge_type
            WHEN 'verified' THEN 'The 50mm Retina World curators have honoured you as a Premium Member. Choose your Featured photo to show on your card.'
            ELSE 'The 50mm Retina World curators have honoured you as an Elite Member.'
          END;

  INSERT INTO public.user_notifications (user_id, actor_id, type, title, message, reference_id, email_sent)
  VALUES (NEW.user_id, NEW.assigned_by, 'badge_awarded', _title, _msg, NEW.id, true);

  -- The e-mail: its own sub-block, so nothing here can stop the badge.
  BEGIN
    SELECT u.email INTO _email FROM auth.users u WHERE u.id = NEW.user_id;
    SELECT coalesce(nullif(p.full_name, ''), 'there'), nullif(p.custom_url, '') INTO _name, _handle
      FROM public.profiles p WHERE p.id = NEW.user_id;
    IF _email IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.suppressed_emails s WHERE s.email = lower(_email)) THEN
      SELECT t.token INTO _token FROM public.email_unsubscribe_tokens t
       WHERE t.email = lower(_email) AND t.used_at IS NULL LIMIT 1;
      IF _token IS NULL THEN
        _token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO public.email_unsubscribe_tokens (token, email) VALUES (_token, lower(_email))
        ON CONFLICT (email) DO NOTHING;
        SELECT t.token INTO _token FROM public.email_unsubscribe_tokens t
         WHERE t.email = lower(_email) AND t.used_at IS NULL LIMIT 1;
      END IF;
      _url := CASE WHEN _handle IS NOT NULL AND _handle ~ '^[A-Za-z0-9._-]+$'
                   THEN 'https://www.50mmretina.com/' || _handle || '?share=honour'
                   ELSE 'https://www.50mmretina.com/premium-members' END;
      _mid := gen_random_uuid()::text;
      _html := '<!DOCTYPE html><html lang="en" dir="ltr"><head><meta charset="utf-8"/></head><body style="background-color:#ffffff;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,sans-serif;"><div style="padding:32px 24px;max-width:480px;margin:0 auto;"><h1 style="font-size:20px;font-weight:700;color:#1c2d41;margin:0 0 8px;">Hi '
            || replace(replace(replace(_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
            || ',</h1><p style="font-size:11px;font-weight:600;color:#0284c7;letter-spacing:0.1em;text-transform:uppercase;margin:0 0 12px;">'
            || _title || '</p><p style="font-size:15px;color:#4b5563;line-height:1.6;margin:0 0 24px;">' || _msg
            || ' Share the news with your friends: one tap makes your honour image.</p><a href="' || _url
            || '" style="display:inline-block;background-color:#0284c7;color:#f0f9ff;padding:12px 28px;border-radius:8px;font-size:14px;font-weight:600;text-decoration:none;">Share my honour</a><hr style="border:none;border-top:1px solid #e5e7eb;margin:28px 0 16px;"/><p style="font-size:12px;color:#9ca3af;line-height:1.5;margin:0;">You are receiving this because the 50mm Retina World curators honoured your account.</p></div></body></html>';
      _text := 'Hi ' || _name || ',' || E'\n\n' || _title || E'\n\n' || _msg || E'\n\n' || 'Share my honour: ' || _url
            || E'\n\n---\nYou are receiving this because the 50mm Retina World curators honoured your account.';
      INSERT INTO public.email_send_log (message_id, template_name, recipient_email, status)
      VALUES (_mid, 'notification-alert', _email, 'pending');
      PERFORM public.enqueue_email('transactional_emails', jsonb_build_object(
        'message_id', _mid, 'to', _email,
        'from', '50mm Retina World <noreply@www.50mmretina.com>',
        'sender_domain', 'notify.www.50mmretina.com',
        'subject', _title || E' — 50mm Retina World', 'html', _html, 'text', _text,
        'purpose', 'transactional', 'label', 'notification-alert',
        'idempotency_key', 'honour-' || NEW.id::text,
        'unsubscribe_token', _token,
        'queued_at', now()::text
      ));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'notify_badge_awarded: honour e-mail not queued for badge %: % / %', NEW.id, SQLSTATE, SQLERRM;
  END;
  RETURN NEW;
END;
$$;

COMMIT;

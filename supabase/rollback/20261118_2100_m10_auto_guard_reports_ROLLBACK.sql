-- ROLLBACK · 20261118_2100 · M10 automatic guard + reports
-- Drops the report functions and table, puts the M2c guard and word-add back (hold allowed again, no link rule).
-- NOT reversed: starter 'hold' rules stay 'block' and the political ones stay switched off (data change, harmless).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.admin_message_watchlist();
DROP FUNCTION IF EXISTS public.admin_message_report_done(bigint, text);
DROP FUNCTION IF EXISTS public.admin_message_reports(text);
DROP FUNCTION IF EXISTS public.message_report(uuid, text, text);
DROP TABLE IF EXISTS public.message_reports;

ALTER TABLE public.message_word_rules DROP CONSTRAINT message_word_rules_action_check;
ALTER TABLE public.message_word_rules ADD CONSTRAINT message_word_rules_action_check CHECK (action IN ('block', 'hold', 'help'));

CREATE OR REPLACE FUNCTION public.message_admin_word_add(_category text, _pattern text, _lang text, _action text, _reason text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _id bigint; _p text := btrim(coalesce(_pattern, ''));
BEGIN
  IF _category NOT IN ('abuse', 'threat', 'political', 'self_harm', 'abnormal') OR _action NOT IN ('block', 'hold', 'help') THEN
    RAISE EXCEPTION 'MSGADM-006: bad category or action' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF char_length(_p) < 2 OR char_length(_p) > 200 THEN
    RAISE EXCEPTION 'MSGADM-006: a word or phrase of 2–200 characters is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  INSERT INTO public.message_word_rules (category, pattern, lang, action, added_by)
  VALUES (_category, _p, nullif(btrim(coalesce(_lang, '')), ''), _action, _uid) RETURNING id INTO _id;
  INSERT INTO public.message_control_log (actor_id, area, old_value, new_value, reason)
  VALUES (_uid, 'word_rule', NULL, format('add #%s %s/%s "%s"', _id, _category, _action, left(_p, 60)), btrim(_reason));
  RETURN _id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.message_word_guard(_uid uuid, _body text)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _hit record;
  _txt text := lower(coalesce(_body, ''));
BEGIN
  SELECT r.id, r.action INTO _hit
    FROM public.message_word_rules r
   WHERE r.active
     AND CASE WHEN r.pattern ~ '^[\x20-\x7E]+$'
              THEN _txt ~ ('\m' || regexp_replace(lower(r.pattern), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
              ELSE position(lower(r.pattern) in _txt) > 0 END
   ORDER BY array_position(ARRAY['block', 'hold', 'help'], r.action), r.id
   LIMIT 1;
  IF NOT FOUND THEN RETURN 'ok'; END IF;
  IF _hit.action = 'help' THEN
    INSERT INTO public.message_guard_events (user_id, rule_id, action) VALUES (_uid, _hit.id, 'help');
    PERFORM public.ops_alarm_set('messages:help', true,
      format('Messages word guard: %s self-harm hit(s) in the last 24 hours — review message_guard_events',
             (SELECT count(*) FROM public.message_guard_events e WHERE e.action = 'help' AND e.created_at > now() - interval '24 hours')),
      jsonb_build_object('latest_user_id', _uid, 'at', now()));
  END IF;
  RETURN _hit.action;
END
$fn$;

REVOKE ALL ON FUNCTION public.message_word_guard(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.message_word_guard(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.message_admin_word_add(text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.message_admin_word_add(text, text, text, text, text) TO authenticated, service_role;

COMMIT;

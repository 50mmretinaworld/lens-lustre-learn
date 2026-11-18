-- ═══════════════════════════════════════════════════════════════════════════
-- 20261118_1800 · M7 — admin chat viewer (always logged), rogue-admin alarm,
--                       held-message review, deletion wipe, daily retention job
-- Needs M1–M5. Owner decisions 15–16 Nov 2026:
--   * no end-to-end privacy: an admin can read any chat any time; EVERY read is logged
--     (who, when, why) before a single message is returned; logs kept 1 year;
--   * an unusual number of chats opened by one admin in a day raises an alarm to the Owner;
--   * admin delete = instant full wipe, no copy kept; only the delete log row stays.
--
--   admin_read_conversation(conversation, reason, before_id, limit) — admin only; writes the
--       message_admin_reads row FIRST; returns members + messages (incl. held / rejected) +
--       photo paths. Photos open through the same logged read: for 10 minutes after it the
--       admin may sign that chat's photo links (message_photo_visible), never otherwise.
--   Alarm 'messages:admin_reads' (ops alarm): fires when one admin opened ≥ 30 different
--       chats in 24 h; evaluated on every read and by the daily job.
--   admin_message_held_queue() / admin_message_review(message, approve, reason) — the word
--       guard's 'hold' queue: approve → delivered (and pushed), reject → never delivered.
--   Deletion wipe: when the delete program writes its 'deleted' log row, message_wipe_member()
--       removes that member's messages, memberships, rules, guard events; chats left empty go.
--       Photo files are queued in message_files_purge (storage refuses SQL deletes of files —
--       the purge runs from an edge job, M7c). A fault never blocks the deletion itself.
--   Retention: job 'message.maintenance' (daily 03:30 UTC, schedules itself): wipes data of
--       members who no longer exist, trims the three logs older than 1 year, re-evaluates the alarm.
--
-- Rollback: supabase/rollback/20261118_1800_m7_admin_viewer_retention_ROLLBACK.sql
-- PROBE:    supabase/migrations/PROBE_20261118_1800_m7_admin_viewer_retention.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF to_regprocedure('public.message_send_core(uuid,text,uuid,jsonb)') IS NULL OR to_regprocedure('public.message_admin_check(text)') IS NULL THEN
    RAISE EXCEPTION 'M7-PRE-001: M2b and M5 must be applied first';
  END IF;
  IF to_regprocedure('public.ops_alarm_set(text,boolean,text,jsonb)') IS NULL OR to_regprocedure('public.account_delete_execute(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'M7-PRE-002: ops_alarm_set or account_delete_execute is missing';
  END IF;
  IF to_regprocedure('public.admin_read_conversation(uuid,text,bigint,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'M7-PRE-003: admin_read_conversation already exists — not re-applying';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

-- ── 1. log rows may also record a held-message review ──────────────────────
ALTER TABLE public.message_control_log DROP CONSTRAINT message_control_log_area_check;
ALTER TABLE public.message_control_log ADD CONSTRAINT message_control_log_area_check
  CHECK (area IN ('mode', 'groups', 'list', 'member_rule', 'word_rule', 'review'));

-- ── 2. the two guards get ONE narrow exception each (set only by the functions below) ──
CREATE OR REPLACE FUNCTION public.message_log_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $fn$
BEGIN
  IF TG_OP = 'DELETE' AND coalesce(current_setting('app.message_log_trim', true), '') = 'on' THEN
    RETURN NULL;                                   -- the 1-year trim of message_logs_trim() only
  END IF;
  RAISE EXCEPTION '% is append-only (% refused)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
END
$fn$;

CREATE OR REPLACE FUNCTION public.messages_no_delete_no_unsend()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $fn$
BEGIN
  IF auth.uid() IS NULL OR coalesce(current_setting('app.message_wipe', true), '') = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;     -- service work / the deletion wipe
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.status = 'held' AND NEW.status IN ('sent', 'rejected')
     AND (NEW.id, NEW.conversation_id, NEW.sender_id, NEW.kind, NEW.body, NEW.client_msg_id, NEW.created_at)
         IS NOT DISTINCT FROM (OLD.id, OLD.conversation_id, OLD.sender_id, OLD.kind, OLD.body, OLD.client_msg_id, OLD.created_at) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'MESSAGE_IMMUTABLE: messages cannot be edited, deleted or unsent' USING ERRCODE = 'insufficient_privilege';
END
$fn$;

-- ── 3. the logged viewer ───────────────────────────────────────────────────
CREATE FUNCTION public.admin_read_conversation(_conversation uuid, _reason text, _before_id bigint DEFAULT NULL, _limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  _uid uuid := public.message_admin_check(_reason);
  _over record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = _conversation) THEN
    RAISE EXCEPTION 'MSGADM-008: no such chat' USING ERRCODE = 'no_data_found';
  END IF;
  -- the log row comes FIRST: no read without a row
  INSERT INTO public.message_admin_reads (admin_id, conversation_id, reason) VALUES (_uid, _conversation, btrim(_reason));
  PERFORM public.message_admin_alarm_eval();
  RETURN jsonb_build_object(
    'conversation_id', _conversation,
    'members', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', m.user_id, 'full_name', p.full_name, 'username', p.custom_url, 'folder', m.folder))
                           FROM public.conversation_members m LEFT JOIN public.profiles p ON p.id = m.user_id
                          WHERE m.conversation_id = _conversation), '[]'::jsonb),
    'messages', coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'sender_id', x.sender_id, 'kind', x.kind, 'body', x.body, 'status', x.status,
                                                              'created_at', x.created_at,
                                                              'photos', coalesce((SELECT jsonb_agg(jsonb_build_object('path', a.storage_path, 'width', a.width, 'height', a.height))
                                                                                    FROM public.message_attachments a WHERE a.message_id = x.id), '[]'::jsonb))
                                           ORDER BY x.id DESC)
                            FROM (SELECT * FROM public.messages m2 WHERE m2.conversation_id = _conversation
                                     AND (_before_id IS NULL OR m2.id < _before_id)
                                   ORDER BY m2.id DESC LIMIT least(greatest(coalesce(_limit, 100), 1), 200)) x), '[]'::jsonb));
END
$fn$;

-- photo links: a member sees their own upload or a chat photo; an admin only within 10 minutes of a logged read
CREATE OR REPLACE FUNCTION public.message_photo_visible(_path text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (SELECT auth.uid()) IS NOT NULL AND (
    ((storage.foldername(_path))[1] = (SELECT auth.uid())::text)
    OR EXISTS (SELECT 1 FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
                WHERE a.storage_path = _path
                  AND public.is_conversation_member(m.conversation_id)
                  AND (m.status = 'sent' OR m.sender_id = (SELECT auth.uid())))
    OR (public.has_role((SELECT auth.uid()), 'admin'::public.app_role)
        AND EXISTS (SELECT 1 FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
                      JOIN public.message_admin_reads r ON r.conversation_id = m.conversation_id
                     WHERE a.storage_path = _path AND r.admin_id = (SELECT auth.uid()) AND r.at > now() - interval '10 minutes')));
$fn$;

-- ── 4. rogue-admin alarm ───────────────────────────────────────────────────
CREATE FUNCTION public.message_admin_alarm_eval()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _w record; _firing boolean;
BEGIN
  SELECT r.admin_id, count(DISTINCT r.conversation_id) AS chats INTO _w
    FROM public.message_admin_reads r WHERE r.at > now() - interval '24 hours'
   GROUP BY r.admin_id HAVING count(DISTINCT r.conversation_id) >= 30
   ORDER BY 2 DESC LIMIT 1;
  _firing := FOUND;
  PERFORM public.ops_alarm_set('messages:admin_reads', _firing,
    CASE WHEN _firing THEN format('One admin opened %s different private chats in 24 hours', _w.chats) ELSE 'Admin chat reads are normal' END,
    CASE WHEN _firing THEN jsonb_build_object('admin_id', _w.admin_id, 'chats_24h', _w.chats) ELSE '{}'::jsonb END);
END
$fn$;

-- ── 5. held-message queue (word guard 'hold') ──────────────────────────────
CREATE FUNCTION public.admin_message_held_queue()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := (SELECT auth.uid());
BEGIN
  IF _uid IS NULL OR NOT public.has_role(_uid, 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'MSGADM-001: only an admin can read the held messages' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('message_id', m.id, 'conversation_id', m.conversation_id, 'sender_id', m.sender_id,
                                                      'sender_name', p.full_name, 'created_at', m.created_at) ORDER BY m.created_at)
                     FROM public.messages m LEFT JOIN public.profiles p ON p.id = m.sender_id WHERE m.status = 'held'), '[]'::jsonb);
END
$fn$;

CREATE FUNCTION public.admin_message_review(_message_id bigint, _approve boolean, _reason text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _uid uuid := public.message_admin_check(_reason); _m public.messages%ROWTYPE; _new text := CASE WHEN _approve THEN 'sent' ELSE 'rejected' END;
BEGIN
  SELECT * INTO _m FROM public.messages WHERE id = _message_id AND status = 'held' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MSGADM-009: no such held message' USING ERRCODE = 'no_data_found'; END IF;
  -- the reviewer reads the text, so the read is logged like any other
  INSERT INTO public.message_admin_reads (admin_id, conversation_id, reason) VALUES (_uid, _m.conversation_id, 'held review: ' || left(btrim(_reason), 450));
  UPDATE public.messages SET status = _new WHERE id = _message_id;
  IF _approve THEN UPDATE public.conversations SET last_message_at = now() WHERE id = _m.conversation_id; END IF;
  INSERT INTO public.message_control_log (actor_id, area, user_id, old_value, new_value, reason)
  VALUES (_uid, 'review', _m.sender_id, 'held #' || _message_id, _new, btrim(_reason));
  RETURN _new;
END
$fn$;

-- ── 6. deletion wipe ───────────────────────────────────────────────────────
CREATE TABLE public.message_files_purge (
  path       text PRIMARY KEY,
  queued_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.message_files_purge ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_files_purge FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_files_purge TO service_role;

CREATE FUNCTION public.message_wipe_member(_uid uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _msgs int; _convs int;
BEGIN
  PERFORM set_config('app.message_wipe', 'on', true);
  INSERT INTO public.message_files_purge (path)
  SELECT a.storage_path FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id WHERE m.sender_id = _uid
  ON CONFLICT DO NOTHING;
  DELETE FROM public.messages WHERE sender_id = _uid;
  GET DIAGNOSTICS _msgs = ROW_COUNT;
  DELETE FROM public.conversation_members WHERE user_id = _uid;
  PERFORM set_config('app.message_log_trim', 'on', true);          -- the append-only guard's one exception
  DELETE FROM public.message_guard_events WHERE user_id = _uid;
  PERFORM set_config('app.message_log_trim', 'off', true);
  DELETE FROM public.message_member_rules WHERE user_id = _uid;
  DELETE FROM public.message_control_members WHERE user_id = _uid;
  -- chats nobody is left in
  INSERT INTO public.message_files_purge (path)
  SELECT a.storage_path FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id
   WHERE m.conversation_id IN (SELECT c.id FROM public.conversations c WHERE NOT EXISTS (SELECT 1 FROM public.conversation_members cm WHERE cm.conversation_id = c.id))
  ON CONFLICT DO NOTHING;
  DELETE FROM public.conversations c WHERE NOT EXISTS (SELECT 1 FROM public.conversation_members cm WHERE cm.conversation_id = c.id);
  GET DIAGNOSTICS _convs = ROW_COUNT;
  PERFORM set_config('app.message_wipe', 'off', true);
  RETURN jsonb_build_object('messages', _msgs, 'chats', _convs);
END
$fn$;

CREATE FUNCTION public.message_wipe_on_delete_log()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  BEGIN
    PERFORM public.message_wipe_member(NEW.user_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'message_wipe_on_delete_log: could not wipe messages of % (%) — the daily job will retry', NEW.user_id, SQLSTATE;
  END;
  RETURN NEW;
END
$fn$;
CREATE TRIGGER message_wipe_on_delete AFTER INSERT ON public.account_state_log
  FOR EACH ROW WHEN (NEW.to_state = 'deleted') EXECUTE FUNCTION public.message_wipe_on_delete_log();

-- ── 7. daily retention job ─────────────────────────────────────────────────
CREATE FUNCTION public.message_logs_trim()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE _a int; _b int; _c int;
BEGIN
  PERFORM set_config('app.message_log_trim', 'on', true);
  DELETE FROM public.message_admin_reads WHERE at < now() - interval '1 year';        GET DIAGNOSTICS _a = ROW_COUNT;
  DELETE FROM public.message_control_log WHERE at < now() - interval '1 year';        GET DIAGNOSTICS _b = ROW_COUNT;
  DELETE FROM public.message_guard_events WHERE created_at < now() - interval '1 year'; GET DIAGNOSTICS _c = ROW_COUNT;
  PERFORM set_config('app.message_log_trim', 'off', true);
  RETURN _a + _b + _c;
END
$fn$;

CREATE FUNCTION public.message_maintenance(_p jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record; _next timestamptz;
BEGIN
  -- members who are gone but whose messages remain (a wipe that faulted, or a deletion path that skipped the log)
  FOR r IN SELECT DISTINCT m.sender_id AS uid FROM public.messages m WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = m.sender_id) LIMIT 200 LOOP
    PERFORM public.message_wipe_member(r.uid);
  END LOOP;
  PERFORM public.message_logs_trim();
  PERFORM public.message_admin_alarm_eval();
  _next := date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + interval '1 day 3 hours 30 minutes';
  PERFORM public.job_enqueue('message.maintenance', '{}'::jsonb, 'maint:' || to_char(_next, 'YYYY-MM-DD'), _next);
END
$fn$;

INSERT INTO public.job_kinds (kind, handler, max_attempts, backoff_seconds, timeout_seconds, max_running, note) VALUES
  ('message.maintenance', 'sql:public.message_maintenance', 4, ARRAY[60, 300, 1800], 120, 1,
   'M7: daily, schedules itself; wipes data of gone members, trims message logs older than 1 year, re-checks the admin-read alarm');
SELECT public.job_enqueue('message.maintenance', '{}'::jsonb,
         'maint:' || to_char(date_trunc('day', now() AT TIME ZONE 'UTC') + interval '1 day', 'YYYY-MM-DD'),
         date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + interval '1 day 3 hours 30 minutes');

-- ── 8. rights ──────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.admin_read_conversation(uuid, text, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_held_queue() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_message_review(bigint, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.message_admin_alarm_eval() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_wipe_member(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_wipe_on_delete_log() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_logs_trim() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.message_maintenance(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_read_conversation(uuid, text, bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_message_held_queue() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_message_review(bigint, boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.message_wipe_member(uuid), public.message_logs_trim(), public.message_maintenance(jsonb), public.message_admin_alarm_eval() TO service_role;

COMMIT;

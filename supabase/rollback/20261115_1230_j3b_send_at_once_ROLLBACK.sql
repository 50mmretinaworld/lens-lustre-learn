-- ROLLBACK · 20261115_1230 · J3b send at once → back to J3a (jobs wait for the tick)
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

-- push_on_notification and job_tick exactly as 20261115_1200 (J3a)
CREATE OR REPLACE FUNCTION public.push_on_notification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _cfg    public.push_config%ROWTYPE;
  _allow  boolean := true;
  _grp    text;
  _ch     jsonb;
  _centre boolean := false;
  _img    text;
  _payload jsonb;
BEGIN
  SELECT * INTO _cfg FROM public.push_config WHERE id LIMIT 1;
  IF _cfg.function_url IS NULL THEN RETURN NEW; END IF;
  IF NEW.actor_id IS NOT NULL AND NEW.actor_id = NEW.user_id THEN RETURN NEW; END IF;

  -- N4 (20261104_0170): for a group switched on for this member, push follows
  -- the notification centre's decision, which the gate (0140) logged for this
  -- very row: the member's per-type push setting for EVERY type, the master
  -- switch, and quiet hours. No logged decision (group off, or a gate fault)
  -- -> exactly today's rules below.
  -- A fault in this lookup must never cost a push: its own block, and on any
  -- error the old rules decide.
  BEGIN
    SELECT nt.group_key INTO _grp FROM public.notification_types nt WHERE nt.type = NEW.type;
    IF _grp IS NOT NULL AND public.notification_centre_live(_grp, NEW.user_id) THEN
      SELECT l.channels INTO _ch
        FROM public.notification_centre_log l
       WHERE l.notification_id = NEW.id
       ORDER BY l.id DESC
       LIMIT 1;
      IF _ch IS NOT NULL THEN
        _centre := true;
        _allow  := coalesce((_ch ->> 'push')::boolean, false);
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    _centre := false;
    RAISE WARNING 'push_on_notification: centre lookup failed (%), using the old rules', SQLSTATE;
  END;

  -- N4 (20261104_0210): a push of a group switched on shows the post's
  -- picture (the 600 px thumbnail, else the photo). send-push only accepts
  -- this lane's own image hosts. Any fault here → no picture, push unchanged.
  IF _centre AND NEW.reference_id IS NOT NULL
     AND NEW.type IN ('post_reaction', 'post_comment', 'comment_reply', 'tagged_post_reaction',
                      'tagged_post_comment', 'new_post_from_following', 'post_tag') THEN
    BEGIN
      -- the bell's own rule (get_my_notifications_grouped): a picture only of a
      -- public post or the recipient's own — never a private / friends-only
      -- post someone was tagged on or replied under
      SELECT coalesce(nullif(p.thumbnail_url, ''), nullif(p.image_url, ''), nullif(p.image_urls[1], '')) INTO _img
        FROM public.posts p
       WHERE p.id = NEW.reference_id
         AND (p.privacy = 'public' OR p.user_id = NEW.user_id);
    EXCEPTION WHEN OTHERS THEN
      _img := NULL;
    END;
  END IF;

  IF NOT _centre THEN
    SELECT CASE
             WHEN np.user_id IS NULL THEN true
             WHEN np.push_enabled = false THEN false
             WHEN NEW.type IN ('post_reaction','image_reaction')            THEN np.push_reactions
             WHEN NEW.type IN ('post_comment','image_comment','comment_reply') THEN np.push_comments
             WHEN NEW.type = 'friend_request'                                THEN np.push_friend_requests
             WHEN NEW.type = 'new_follower'                                  THEN np.push_new_followers
             WHEN NEW.type = 'new_post_from_following'                       THEN np.push_new_posts
             WHEN NEW.type IN ('competition_vote','entry_approved','entry_rejected',
                               'competition_winner','new_competition')       THEN np.push_competition_updates
             -- ADDED 2026-08-15: the two platform broadcasts. Placed ABOVE
             -- `ELSE true` so they cannot fall through to it, and BELOW the
             -- specific branches above so it cannot swallow one of them.
             -- Neither type appears in any earlier branch (verified against the
             -- live definition before this was written), so nothing above shadows
             -- it and it shadows nothing.
             WHEN NEW.type IN ('journal_published','course_published')        THEN np.push_announcements
             ELSE true
           END
      INTO _allow
    FROM (SELECT 1) AS _one
    LEFT JOIN public.notification_preferences np ON np.user_id = NEW.user_id;
  END IF;
  IF _allow IS DISTINCT FROM true THEN RETURN NEW; END IF;
  _payload := jsonb_build_object('user_id', NEW.user_id, 'title', NEW.title,
                 'body', public.notif_push_body(NEW.type, NEW.actor_id, NEW.message),
                 'data', CASE WHEN _centre
                              -- notification_id lets send-push link its receipt (N4, 0160)
                              THEN jsonb_build_object('type', NEW.type, 'reference_id', COALESCE(NEW.reference_id::text,''),
                                                      'notification_id', NEW.id::text)
                              ELSE jsonb_build_object('type', NEW.type, 'reference_id', COALESCE(NEW.reference_id::text,''))
                         END)
               -- the picture key only when there is one: a push of a group that is
               -- off sends exactly today's request
               || CASE WHEN _img IS NOT NULL THEN jsonb_build_object('image_url', _img) ELSE '{}'::jsonb END;
  -- J3a (20261115_1200): with the engine and the push group switched on, the
  -- push becomes a job — retried 1/5/30 min, 60 s to finish, failed list +
  -- alarm. Switch off, or the job cannot be written: exactly today's call.
  IF coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine'), false)
     AND coalesce((SELECT f.value FROM public.system_flags f WHERE f.key = 'job_engine_push'), false) THEN
    BEGIN
      PERFORM public.job_enqueue('push.send', _payload, 'notification:' || NEW.id::text);
      RETURN NEW;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'push_on_notification: job_enqueue failed (%), sending directly', SQLSTATE;
    END;
  END IF;
  PERFORM net.http_post(
    url     := _cfg.function_url,
    headers := jsonb_build_object('Content-Type','application/json','x-internal-secret', _cfg.internal_secret),
    body    := _payload
  );
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'push_on_notification failed for user % : % / %', NEW.user_id, SQLSTATE, SQLERRM;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.push_on_notification() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.job_tick()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  r record;
  k record;
  j public.jobs;
  _on boolean;
  _edge jsonb;
  _proc regprocedure;
  _req bigint;
  _slots integer;
  _budget integer := 50;
  _done integer := 0; _retry integer := 0; _failed integer := 0; _started integer := 0;
  _res text;
  _bad integer; _late integer;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('public.job_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tick is running');
  END IF;
  SELECT value INTO _on FROM public.system_flags WHERE key = 'job_engine';

  IF coalesce(_on, false) THEN
    -- (a) settle edge calls from their real HTTP result
    FOR r IN
      SELECT jb.id, resp.status_code, resp.timed_out, resp.error_msg, (resp.id IS NOT NULL) AS answered, jb.lease_until
        FROM public.jobs jb
        LEFT JOIN net._http_response resp ON resp.id = jb.net_request_id
       WHERE jb.status = 'running' AND jb.net_request_id IS NOT NULL
       FOR UPDATE OF jb SKIP LOCKED
    LOOP
      IF r.answered AND r.status_code BETWEEN 200 AND 299 THEN
        UPDATE public.jobs SET status = 'done', lease_until = NULL, finished_at = now(), updated_at = now(),
                               last_error = NULL WHERE id = r.id;
        _done := _done + 1;
      ELSIF r.answered THEN
        _res := public.job_fail_attempt(r.id, CASE WHEN r.timed_out THEN 'timed out'
                                                   WHEN r.error_msg IS NOT NULL THEN r.error_msg
                                                   ELSE 'HTTP ' || coalesce(r.status_code::text, '?') END);
        IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
      ELSIF r.lease_until < now() THEN
        _res := public.job_fail_attempt(r.id, 'no answer before the lease ran out');
        IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
      END IF;
    END LOOP;

    -- (b) free stuck work (a run that died without settling)
    FOR r IN
      SELECT id FROM public.jobs
       WHERE status = 'running' AND net_request_id IS NULL AND lease_until < now()
       FOR UPDATE SKIP LOCKED
    LOOP
      _res := public.job_fail_attempt(r.id, 'stuck: lease ran out');
      IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
    END LOOP;

    -- (c) claim and run due work, per kind within its limit
    SELECT decrypted_secret::jsonb INTO _edge FROM vault.decrypted_secrets WHERE name = 'jobs:edge';
    FOR k IN
      SELECT jk.*, (SELECT count(*) FROM public.jobs x WHERE x.kind = jk.kind AND x.status = 'running') AS running_now
        FROM public.job_kinds jk
       WHERE jk.enabled
         AND EXISTS (SELECT 1 FROM public.jobs q WHERE q.kind = jk.kind AND q.status = 'queued' AND q.run_at <= now())
       ORDER BY jk.kind
    LOOP
      _slots := least(k.max_running - k.running_now, _budget);
      CONTINUE WHEN _slots <= 0;
      FOR j IN
        SELECT * FROM public.jobs
         WHERE kind = k.kind AND status = 'queued' AND run_at <= now()
         ORDER BY run_at, id
         LIMIT _slots
         FOR UPDATE SKIP LOCKED
      LOOP
        _budget := _budget - 1;
        UPDATE public.jobs SET status = 'running', attempts = attempts + 1, started_at = now(),
                               lease_until = now() + make_interval(secs => k.timeout_seconds), updated_at = now()
         WHERE id = j.id;
        _started := _started + 1;
        IF k.handler LIKE 'sql:%' THEN
          BEGIN
            _proc := to_regprocedure(substr(k.handler, 5) || '(jsonb)');
            IF _proc IS NULL THEN
              RAISE EXCEPTION 'handler % (jsonb) does not exist', substr(k.handler, 5);
            END IF;
            -- handler text is pinned by the job_kinds CHECK to public.<lowercase identifier>
            EXECUTE format('SELECT %s($1)', substr(k.handler, 5)) USING j.payload;
            UPDATE public.jobs SET status = 'done', lease_until = NULL, finished_at = now(), updated_at = now(),
                                   last_error = NULL WHERE id = j.id;
            _done := _done + 1;
          EXCEPTION WHEN OTHERS THEN
            _res := public.job_fail_attempt(j.id, SQLSTATE || ' ' || SQLERRM);
            IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
          END;
        ELSE
          IF _edge IS NULL OR _edge->>'base_url' IS NULL THEN
            _res := public.job_fail_attempt(j.id, 'no vault target jobs:edge on this lane');
            IF _res = 'failed' THEN _failed := _failed + 1; ELSE _retry := _retry + 1; END IF;
          ELSE
            _req := net.http_post(
              url := (_edge->>'base_url') || '/functions/v1/' || substr(k.handler, 6),
              body := j.payload || jsonb_build_object('job_id', j.id, 'attempt', j.attempts + 1),
              params := '{}'::jsonb,
              -- J3a: a kind may add headers kept in its own vault secret (never in a table)
              headers := coalesce(_edge->'headers', '{"Content-Type": "application/json"}'::jsonb)
                         || coalesce((SELECT ds.decrypted_secret::jsonb FROM vault.decrypted_secrets ds
                                       WHERE ds.name = k.extra_headers_secret), '{}'::jsonb),
              timeout_milliseconds := k.timeout_seconds * 1000);
            UPDATE public.jobs SET net_request_id = _req WHERE id = j.id;
          END IF;
        END IF;
        EXIT WHEN _budget <= 0;
      END LOOP;
      EXIT WHEN _budget <= 0;
    END LOOP;
  END IF;

  -- (d) J2 alarms — evaluated even with the switch off, so leftovers are seen
  SELECT count(*) INTO _bad FROM public.jobs WHERE status = 'failed' AND finished_at > now() - interval '24 hours';
  SELECT count(*) INTO _late FROM public.jobs WHERE status = 'queued' AND run_at < now() - interval '10 minutes'
                                                   AND attempts = 0;
  PERFORM public.ops_alarm_set('jobs:failed', _bad > 0,
    format('%s background job(s) failed in the last 24 hours', _bad), jsonb_build_object('failed_24h', _bad));
  PERFORM public.ops_alarm_set('jobs:overdue', coalesce(_on, false) AND _late > 0,
    format('%s background job(s) waiting more than 10 minutes', _late), jsonb_build_object('overdue', _late));

  -- (e) trim the book
  DELETE FROM public.jobs WHERE status = 'done' AND finished_at < now() - interval '14 days';
  DELETE FROM public.jobs WHERE status IN ('failed', 'cancelled') AND finished_at < now() - interval '90 days';

  RETURN jsonb_build_object('on', coalesce(_on, false), 'started', _started, 'done', _done,
                            'retry', _retry, 'failed', _failed, 'failed_24h', _bad, 'overdue', _late);
END
$fn$;
REVOKE ALL ON FUNCTION public.job_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.job_tick() TO service_role;

REVOKE ALL ON FUNCTION public.job_start(bigint) FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION public.job_start(bigint);

COMMIT;

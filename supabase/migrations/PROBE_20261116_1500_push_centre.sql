-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261116_1500 push centre PN1. READ ONLY, ROLLBACK.
-- COUNTS ONLY — no member id, name, e-mail or device token is printed.
--
-- Always reports first: devices by app capability, members last seen in the
-- app with / without a device, the scheduling switch, and broadcasts by status.
-- PASS = every 1500 object is present as 1500 creates it (definer, search_path
-- '', grants, admin gate, job kind). Before the apply it FAILS (expected).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;

DO $p$
DECLARE
  n text; f oid; r record; line text := '';
  applied boolean := to_regclass('public.push_broadcasts') IS NOT NULL;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;

  SELECT count(*) AS devices, count(DISTINCT user_id) AS members INTO r FROM public.push_tokens;
  RAISE NOTICE 'DEVICES (lane %): % devices of % members', current_setting('p32.lane'), r.devices, r.members;
  SELECT count(*) FILTER (WHERE p.last_platform = 'app') AS app,
         count(*) FILTER (WHERE p.last_platform = 'app'
                            AND EXISTS (SELECT 1 FROM public.push_tokens t WHERE t.user_id = p.id)) AS app_dev,
         count(*) FILTER (WHERE p.last_platform = 'app' AND p.last_active_at >= now() - interval '30 days'
                            AND NOT EXISTS (SELECT 1 FROM public.push_tokens t WHERE t.user_id = p.id)) AS app_recent_none,
         count(*) FILTER (WHERE p.last_platform IS DISTINCT FROM 'app'
                            AND EXISTS (SELECT 1 FROM public.push_tokens t WHERE t.user_id = p.id)) AS other_dev
    INTO r FROM public.profiles p;
  RAISE NOTICE 'APP MEMBERS: last seen in app=% · with a device=% · seen in app in 30 days but no device=% · devices of members last seen elsewhere=%',
    r.app, r.app_dev, r.app_recent_none, r.other_dev;
  RAISE NOTICE 'SCHEDULING SWITCH job_engine=%',
    coalesce((SELECT value::text FROM public.system_flags WHERE key = 'job_engine'), '(absent)');

  IF applied THEN
    FOR r IN EXECUTE $q$SELECT CASE WHEN 'rich' = ANY (caps) THEN 'rich' ELSE 'plain' END AS c, count(*) AS n
                          FROM public.push_tokens GROUP BY 1 ORDER BY 1$q$ LOOP
      line := line || format(' %s=%s', r.c, r.n);
    END LOOP;
    RAISE NOTICE 'DEVICE BUILDS:%', coalesce(nullif(line, ''), ' none');
    line := '';
    FOR r IN EXECUTE $q$SELECT kind || '/' || status AS s, count(*) AS n FROM public.push_broadcasts GROUP BY 1 ORDER BY 1$q$ LOOP
      line := line || format(' %s=%s', r.s, r.n);
    END LOOP;
    RAISE NOTICE 'BROADCASTS:%', coalesce(nullif(line, ''), ' none');
    line := '';
    FOR r IN EXECUTE $q$SELECT permission AS s, count(*) AS n FROM public.push_permission_state GROUP BY 1 ORDER BY 1$q$ LOOP
      line := line || format(' %s=%s', r.s, r.n);
    END LOOP;
    RAISE NOTICE 'PERMISSION ANSWERS:%', coalesce(nullif(line, ''), ' none yet');
  END IF;

  IF NOT applied OR to_regclass('public.push_permission_state') IS NULL THEN
    RAISE EXCEPTION 'PROBE FAIL: push_broadcasts / push_permission_state missing (1500 not applied)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'push_tokens'
                  AND column_name IN ('app_version', 'caps') HAVING count(*) = 2) THEN
    RAISE EXCEPTION 'PROBE FAIL: push_tokens.app_version / caps missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND table_name = 'notification_deliveries' AND column_name = 'broadcast_id') THEN
    RAISE EXCEPTION 'PROBE FAIL: notification_deliveries.broadcast_id missing';
  END IF;

  FOREACH n IN ARRAY ARRAY[
    'public.admin_push_audience(jsonb)', 'public.admin_push_broadcast_save(bigint, jsonb)',
    'public.admin_push_broadcast_schedule(bigint, timestamp with time zone)',
    'public.admin_push_broadcast_cancel(bigint)', 'public.admin_push_broadcast_delete(bigint)',
    'public.admin_push_broadcasts(text, integer, integer)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL OR NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=""'] FROM pg_proc WHERE oid = f) THEN
      RAISE EXCEPTION 'PROBE FAIL: % missing or not SECURITY DEFINER with search_path=""', n;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) x WHERE p.oid = f AND x.grantee = 0) THEN
      RAISE EXCEPTION 'PROBE FAIL: % EXECUTE is not authenticated-only', n;
    END IF;
    IF position('has_role(' IN pg_get_functiondef(f)) = 0 OR position('Not authorized' IN pg_get_functiondef(f)) = 0 THEN
      RAISE EXCEPTION 'PROBE FAIL: % has no admin gate', n;
    END IF;
  END LOOP;

  FOREACH n IN ARRAY ARRAY['public.register_push_device(text, text, text, text[])',
                           'public.report_push_permission(text, text, text)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL OR has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'PROBE FAIL: % missing or not authenticated-only', n;
    END IF;
  END LOOP;

  FOREACH n IN ARRAY ARRAY['public.push_broadcast_claim(bigint)', 'public.push_broadcast_finish(bigint, jsonb, text)',
                           'public.push_broadcast_targets(bigint, bigint, integer)',
                           'public.push_audience_members(jsonb)', 'public.push_audience_check(jsonb)'] LOOP
    f := to_regprocedure(n);
    IF f IS NULL OR has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'PROBE FAIL: % missing or callable by a client role', n;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM public.job_kinds WHERE kind = 'push.broadcast' AND enabled
                  AND handler = 'edge:send-broadcast-push' AND extra_headers_secret = 'jobs:edge:send-push') THEN
    RAISE EXCEPTION 'PROBE FAIL: job kind push.broadcast missing or changed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_push_broadcast_count_open' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'PROBE FAIL: opened-count trigger missing';
  END IF;

  RAISE NOTICE 'PROBE PASS: 20261116_1500 present as intended';
END
$p$;

ROLLBACK;

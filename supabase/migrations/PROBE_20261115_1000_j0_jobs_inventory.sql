-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1000 — J0: inventory of every background job (job engine plan).
-- READ-ONLY in effect: one transaction, ROLLBACK. Prints names, schedules,
-- counts and masked error snippets only — NEVER a cron command's text (it can
-- hold keys), never ids, e-mails or row contents. Diagnostic only — never fails
-- on findings.
--   J0-A extensions (pg_cron, pg_net, pgmq)
--   J0-B every cron job: name, schedule, active, target (edge fn / SQL fn only)
--   J0-C cron run health, last 7 days: runs, failures, last failure, max time
--   J0-D pg_net HTTP results still kept (status classes)
--   J0-E queue-like public tables: rows per status, oldest waiting age
--   J0-F functions that call net.http_post, and the triggers that fire them
--   J0-G database webhooks (supabase_functions)
--   J0-H alarm settings tables (counts and column names only)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  r record; q record; _n bigint; _t text; _sql text; _cols text;
  _mask text := '[A-Za-z0-9_\-\.=+/]{20,}';
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'J0 lane %', current_setting('p32.lane', true);

  -- J0-A
  FOR r IN SELECT extname, extversion FROM pg_extension
           WHERE extname IN ('pg_cron', 'pg_net', 'pgmq', 'pg_jsonschema') ORDER BY 1 LOOP
    RAISE NOTICE 'J0-A ext % %', r.extname, r.extversion;
  END LOOP;

  -- J0-B
  IF to_regclass('cron.job') IS NOT NULL THEN
    SELECT count(*) INTO _n FROM cron.job;
    RAISE NOTICE 'J0-B cron jobs total %', _n;
    FOR r IN EXECUTE $q$
      SELECT jobid, jobname, schedule, active,
             CASE
               WHEN command ~* 'functions/v1/[a-z0-9_-]+'
                 THEN 'edge:' || substring(command FROM '(?i)functions/v1/([a-z0-9_-]+)')
               WHEN command ~* 'net\.http_(post|get)'
                 THEN 'http:other'
               WHEN command ~* '(select|perform|call)\s+[a-z0-9_\.]+\s*\('
                 THEN 'sql:' || lower(substring(command FROM '(?i)(?:select|perform|call)\s+([a-z0-9_\.]+)\s*\('))
               ELSE 'sql:other(len ' || length(command) || ')'
             END AS target
      FROM cron.job ORDER BY jobname $q$ LOOP
      RAISE NOTICE 'J0-B job | % | % | active=% | %', coalesce(r.jobname, '#' || r.jobid), r.schedule, r.active, r.target;
    END LOOP;
  ELSE
    RAISE NOTICE 'J0-B cron.job absent';
  END IF;

  -- J0-C
  IF to_regclass('cron.job_run_details') IS NOT NULL THEN
    FOR r IN EXECUTE format($q$
      SELECT coalesce(j.jobname, '#' || d.jobid) AS name,
             count(*) AS runs,
             count(*) FILTER (WHERE d.status = 'failed') AS failed,
             count(*) FILTER (WHERE d.status NOT IN ('failed', 'succeeded')) AS other,
             max(d.start_time) FILTER (WHERE d.status = 'failed') AS last_fail,
             max(d.start_time) AS last_run,
             round(extract(epoch FROM max(d.end_time - d.start_time))::numeric, 1) AS max_s,
             left(regexp_replace((array_agg(d.return_message ORDER BY d.start_time DESC)
                    FILTER (WHERE d.status = 'failed'))[1], %L, '***', 'g'), 90) AS last_msg
      FROM cron.job_run_details d LEFT JOIN cron.job j USING (jobid)
      WHERE d.start_time > now() - interval '7 days'
      GROUP BY 1 ORDER BY 3 DESC, 1 $q$, _mask) LOOP
      RAISE NOTICE 'J0-C run | % | runs=% failed=% other=% | last_run=% last_fail=% | max_s=% | %',
        r.name, r.runs, r.failed, r.other, r.last_run, r.last_fail, r.max_s, coalesce(r.last_msg, '-');
    END LOOP;
  END IF;

  -- J0-D
  IF to_regclass('net._http_response') IS NOT NULL THEN
    FOR r IN EXECUTE $q$
      SELECT CASE WHEN status_code IS NULL THEN 'no-status' ELSE (status_code / 100) || 'xx' END AS cls,
             count(*) AS n, min(created) AS oldest, max(created) AS newest,
             count(*) FILTER (WHERE error_msg IS NOT NULL) AS with_error
      FROM net._http_response GROUP BY 1 ORDER BY 1 $q$ LOOP
      RAISE NOTICE 'J0-D http % n=% err=% window % .. %', r.cls, r.n, r.with_error, r.oldest, r.newest;
    END LOOP;
    FOR r IN EXECUTE format($q$
      SELECT left(regexp_replace(error_msg, %L, '***', 'g'), 80) AS m, count(*) AS n
      FROM net._http_response WHERE error_msg IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 5 $q$, _mask) LOOP
      RAISE NOTICE 'J0-D http-error x% | %', r.n, r.m;
    END LOOP;
  END IF;

  -- J0-E
  FOR q IN
    SELECT c.oid, c.relname,
           (SELECT string_agg(a.attname, ',' ORDER BY a.attnum) FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND a.attname ~ '^(status|state|attempts?|attempt_count|retry_count|retries|tries|next_attempt_at|next_retry_at|run_at|scheduled_for|locked_until|locked_at|processed_at|sent_at|last_error|error)$') AS jobcols,
           EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname IN ('status', 'state') AND NOT a.attisdropped) AS has_status,
           EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'created_at' AND NOT a.attisdropped) AS has_created
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
      AND (c.relname ~ '(queue|jobs?|outbox|deliver|pending|retry|dispatch|schedul)'
           OR EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND NOT a.attisdropped
                        AND a.attname IN ('attempts', 'attempt_count', 'retry_count', 'retries', 'next_attempt_at', 'next_retry_at', 'locked_until')))
    ORDER BY c.relname
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I', q.relname) INTO _n;
    RAISE NOTICE 'J0-E queue % rows=% cols=[%]', q.relname, _n, coalesce(q.jobcols, '');
    IF q.has_status AND _n > 0 THEN
      _t := CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = q.oid AND attname = 'status') THEN 'status' ELSE 'state' END;
      _sql := format('SELECT %1$I::text AS s, count(*) AS n%2$s FROM public.%3$I GROUP BY 1 ORDER BY 2 DESC LIMIT 8',
                     _t, CASE WHEN q.has_created THEN ', round(extract(epoch FROM now() - min(created_at)) / 3600, 1) AS oldest_h' ELSE ', NULL::numeric AS oldest_h' END,
                     q.relname);
      FOR r IN EXECUTE _sql LOOP
        RAISE NOTICE 'J0-E   % %=% n=% oldest_h=%', q.relname, _t, coalesce(r.s, '<null>'), r.n, r.oldest_h;
      END LOOP;
    END IF;
  END LOOP;

  -- J0-F
  FOR r IN
    SELECT p.oid, n.nspname || '.' || p.proname AS fn,
           (SELECT count(*) FROM pg_trigger t WHERE t.tgfoid = p.oid AND NOT t.tgisinternal) AS trig_n,
           (SELECT string_agg(DISTINCT t.tgrelid::regclass::text, ',') FROM pg_trigger t
             WHERE t.tgfoid = p.oid AND NOT t.tgisinternal) AS on_tables
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('net', 'extensions', 'pg_catalog', 'information_schema', 'supabase_functions', 'cron')
      AND p.prosrc ~* 'net\.http_(post|get)'
    ORDER BY 2
  LOOP
    RAISE NOTICE 'J0-F http-caller % | edge=% | triggers=% on [%]', r.fn,
      coalesce((SELECT string_agg(DISTINCT m[1], ',') FROM regexp_matches((SELECT prosrc FROM pg_proc WHERE oid = r.oid), '(?i)functions/v1/([a-z0-9_-]+)', 'g') m), '?'),
      r.trig_n, coalesce(r.on_tables, '-');
  END LOOP;

  -- J0-G
  IF to_regclass('supabase_functions.hooks') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM supabase_functions.hooks' INTO _n;
    RAISE NOTICE 'J0-G webhook log rows %', _n;
  END IF;
  FOR r IN
    SELECT t.tgname, t.tgrelid::regclass::text AS tbl
    FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'supabase_functions' AND NOT t.tgisinternal ORDER BY 2, 1
  LOOP
    RAISE NOTICE 'J0-G db-webhook % on %', r.tgname, r.tbl;
  END LOOP;

  -- J0-H
  FOR q IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname ~ '(alarm|monitor|ops_)' ORDER BY 1 LOOP
    EXECUTE format('SELECT count(*) FROM public.%I', q.relname) INTO _n;
    SELECT string_agg(attname, ',' ORDER BY attnum) INTO _cols FROM pg_attribute
      WHERE attrelid = ('public.' || quote_ident(q.relname))::regclass AND attnum > 0 AND NOT attisdropped;
    RAISE NOTICE 'J0-H alarm-table % rows=% cols=[%]', q.relname, _n, _cols;
  END LOOP;

  RAISE NOTICE 'J0 DONE';
END
$p$;

ROLLBACK;

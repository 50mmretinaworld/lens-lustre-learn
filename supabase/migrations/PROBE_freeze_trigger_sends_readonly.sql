-- PROBE (READ ONLY, ends in ROLLBACK) — Owner 28 Nov: slowness, proof only.
-- Measured (#1333): on 27 Nov member requests rose at 06:38 UTC (12:08 IST) and the database's first trouble came at
-- 06:42; screen opens rose 5-7x — real members arriving. This asks WHAT was sent to members around then:
--   A · push broadcasts (Admin → Push) started/scheduled 27 Nov 05:30-08:00 UTC
--   B · message broadcasts (Admin → Messages → Broadcast) started/finished then, with member counts
--   C · per minute 06:20-07:20 UTC: push deliveries (by type), message-broadcast deliveries, notifications written (by type)
-- Counts, types and times only: no member ids, no text bodies.
BEGIN;
SET TRANSACTION READ ONLY;
DO $$
DECLARE
  r record;
  line text;
  t0 constant timestamptz := '2026-11-27 05:30+00';
  t1 constant timestamptz := '2026-11-27 08:00+00';
BEGIN
  line := '';
  FOR r IN
    SELECT id, kind, status, to_char(coalesce(started_at, scheduled_at, created_at), 'HH24:MI:SS') AS at
      FROM public.push_broadcasts
     WHERE coalesce(started_at, scheduled_at, created_at) BETWEEN t0 AND t1
     ORDER BY coalesce(started_at, scheduled_at, created_at)
  LOOP
    line := line || E'\n  #' || r.id || ' ' || coalesce(r.kind, '?') || ' ' || coalesce(r.status, '?') || ' at ' || r.at || ' UTC';
  END LOOP;
  RAISE NOTICE 'A · PUSH BROADCASTS:%', coalesce(nullif(line, ''), E'\n  (none in the window)');

  line := '';
  FOR r IN
    SELECT id, status, total_members, push, to_char(started_at, 'HH24:MI:SS') AS s, to_char(finished_at, 'HH24:MI:SS') AS f, to_char(send_at, 'HH24:MI:SS') AS sa
      FROM public.message_broadcasts
     WHERE coalesce(started_at, send_at, created_at) BETWEEN t0 AND t1 OR finished_at BETWEEN t0 AND t1
     ORDER BY coalesce(started_at, send_at, created_at)
  LOOP
    line := line || E'\n  #' || r.id || ' ' || coalesce(r.status, '?') || ' members=' || coalesce(r.total_members::text, '?') || ' push=' || coalesce(r.push::text, '?')
                 || ' send_at=' || coalesce(r.sa, '-') || ' started=' || coalesce(r.s, '-') || ' finished=' || coalesce(r.f, '-') || ' UTC';
  END LOOP;
  RAISE NOTICE 'B · MESSAGE BROADCASTS:%', coalesce(nullif(line, ''), E'\n  (none in the window)');

  line := '';
  FOR r IN
    WITH m AS (SELECT generate_series('2026-11-27 06:20+00'::timestamptz, '2026-11-27 07:19+00'::timestamptz, interval '1 minute') AS t)
    SELECT to_char(m.t, 'HH24:MI') AS t,
           (SELECT count(*) FROM public.notification_deliveries d WHERE d.created_at >= m.t AND d.created_at < m.t + interval '1 minute') AS pushes,
           (SELECT string_agg(x.type || '=' || x.n, ' ') FROM (SELECT d.type, count(*) AS n FROM public.notification_deliveries d
               WHERE d.created_at >= m.t AND d.created_at < m.t + interval '1 minute' GROUP BY d.type ORDER BY count(*) DESC LIMIT 3) x) AS push_types,
           (SELECT count(*) FROM public.message_broadcast_recipients b WHERE b.delivered_at >= m.t AND b.delivered_at < m.t + interval '1 minute') AS bc,
           (SELECT count(*) FROM public.user_notifications n WHERE n.created_at >= m.t AND n.created_at < m.t + interval '1 minute') AS notes
      FROM m ORDER BY m.t
  LOOP
    IF r.pushes + r.bc + r.notes > 0 THEN
      line := line || E'\n  ' || r.t || ' UTC  pushes=' || r.pushes || coalesce(' (' || r.push_types || ')', '') || '  broadcast_msgs=' || r.bc || '  notifications=' || r.notes;
    END IF;
  END LOOP;
  RAISE NOTICE 'C · PER MINUTE 06:20-07:19 UTC:%', coalesce(nullif(line, ''), E'\n  (nothing sent)');
END $$;
ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · one chat's message COUNTS (Owner 23 Nov: "200 sent, only a few
-- showing"). READ ONLY, ROLLBACK. Prints counts per sender ROLE (member /
-- admin) and status, per day and per minute peak — NO message text, NO names,
-- NO member ids. Answers: did all 200 reach the server, or were some refused
-- (the 20-a-minute rule for members), held by the word guard, or deleted?
-- Applied only via apply-migration.yml.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';

DO $g$ BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
END $g$;

DO $p$
DECLARE
  _c constant uuid := 'a3a0253c-76c7-493c-8aba-6f0b46119de1';
  r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.conversations WHERE id = _c) THEN
    RAISE NOTICE 'CHAT4700 lane %: this conversation is not on this lane', current_setting('p32.lane');
    RETURN;
  END IF;
  RAISE NOTICE 'CHAT4700 lane % members %', current_setting('p32.lane'),
    (SELECT count(*) FROM public.conversation_members WHERE conversation_id = _c);
  FOR r IN
    SELECT CASE WHEN public.has_role(m.sender_id, 'admin'::public.app_role) THEN 'admin' ELSE 'member' END AS who,
           m.status, count(*) AS n, min(m.created_at)::timestamp(0) AS first_at, max(m.created_at)::timestamp(0) AS last_at
      FROM public.messages m WHERE m.conversation_id = _c
     GROUP BY 1, 2 ORDER BY 1, 2
  LOOP
    RAISE NOTICE 'CHAT4700_COUNT|%|%|%|%|%', r.who, r.status, r.n, r.first_at, r.last_at;
  END LOOP;
  FOR r IN
    SELECT CASE WHEN public.has_role(m.sender_id, 'admin'::public.app_role) THEN 'admin' ELSE 'member' END AS who,
           date_trunc('minute', m.created_at)::timestamp(0) AS minute, count(*) AS n
      FROM public.messages m WHERE m.conversation_id = _c
     GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 5
  LOOP
    RAISE NOTICE 'CHAT4700_PEAK_MINUTE|%|%|%', r.who, r.minute, r.n;
  END LOOP;
  -- What the chat screen's first page returns (the newest 50 visible) vs everything visible.
  RAISE NOTICE 'CHAT4700_VISIBLE|sent %|attachments %',
    (SELECT count(*) FROM public.messages m WHERE m.conversation_id = _c AND m.status = 'sent'),
    (SELECT count(*) FROM public.message_attachments a JOIN public.messages m ON m.id = a.message_id WHERE m.conversation_id = _c);
END
$p$;

ROLLBACK;

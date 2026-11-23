-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · where did "200 sent" go? (Owner 23 Nov, chat a3a0253c…). READ ONLY,
-- ROLLBACK. PROBE 4700: that chat holds ONE message in all. This one counts,
-- for the two members of that chat (ids never printed, called A = the admin
-- member, B = the other): every chat the two share (kind, age, messages,
-- cleared flags), and each one's messages stored today in ALL chats by status.
-- No text, no names, no ids. Applied only via apply-migration.yml.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';

DO $p$
DECLARE
  _c constant uuid := 'a3a0253c-76c7-493c-8aba-6f0b46119de1';
  _a uuid; _b uuid;
  r record;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  SELECT min(cm.user_id::text) FILTER (WHERE public.has_role(cm.user_id, 'admin'::public.app_role))::uuid,
         min(cm.user_id::text) FILTER (WHERE NOT public.has_role(cm.user_id, 'admin'::public.app_role))::uuid
    INTO _a, _b FROM public.conversation_members cm WHERE cm.conversation_id = _c;
  IF _a IS NULL OR _b IS NULL THEN
    SELECT min(cm.user_id::text)::uuid, max(cm.user_id::text)::uuid INTO _a, _b FROM public.conversation_members cm WHERE cm.conversation_id = _c;
  END IF;
  RAISE NOTICE 'CHAT4701 lane % · A is admin: % · B is admin: %', current_setting('p32.lane'),
    public.has_role(_a, 'admin'::public.app_role), public.has_role(_b, 'admin'::public.app_role);

  FOR r IN
    SELECT c.id = _c AS this_chat, c.kind, c.created_at::timestamp(0) AS created,
           (SELECT count(*) FROM public.messages m WHERE m.conversation_id = c.id) AS msgs,
           (SELECT count(*) FROM public.messages m WHERE m.conversation_id = c.id AND m.sender_id = _a) AS by_a,
           (SELECT count(*) FROM public.messages m WHERE m.conversation_id = c.id AND m.sender_id = _b) AS by_b,
           (SELECT max(m.created_at)::timestamp(0) FROM public.messages m WHERE m.conversation_id = c.id) AS last_msg,
           (SELECT cm.cleared_at IS NOT NULL FROM public.conversation_members cm WHERE cm.conversation_id = c.id AND cm.user_id = _a) AS a_cleared,
           (SELECT cm.cleared_at IS NOT NULL FROM public.conversation_members cm WHERE cm.conversation_id = c.id AND cm.user_id = _b) AS b_cleared
      FROM public.conversations c
     WHERE EXISTS (SELECT 1 FROM public.conversation_members x WHERE x.conversation_id = c.id AND x.user_id = _a)
       AND EXISTS (SELECT 1 FROM public.conversation_members y WHERE y.conversation_id = c.id AND y.user_id = _b)
     ORDER BY c.created_at
  LOOP
    RAISE NOTICE 'CHAT4701_SHARED|this %|kind %|created %|msgs %|by A %|by B %|last %|A cleared %|B cleared %',
      r.this_chat, r.kind, r.created, r.msgs, r.by_a, r.by_b, r.last_msg, r.a_cleared, r.b_cleared;
  END LOOP;

  FOR r IN
    SELECT CASE WHEN m.sender_id = _a THEN 'A' ELSE 'B' END AS who, m.status, count(*) AS n,
           count(DISTINCT m.conversation_id) AS chats, max(count(*)) OVER () AS _x
      FROM public.messages m
     WHERE m.sender_id IN (_a, _b) AND m.created_at > now() - interval '2 days'
     GROUP BY 1, 2 ORDER BY 1, 2
  LOOP
    RAISE NOTICE 'CHAT4701_SENT_2DAYS|%|%|% messages in % chats', r.who, r.status, r.n, r.chats;
  END LOOP;
  FOR r IN
    SELECT CASE WHEN m.sender_id = _a THEN 'A' ELSE 'B' END AS who, date_trunc('minute', m.created_at)::timestamp(0) AS minute, count(*) AS n
      FROM public.messages m
     WHERE m.sender_id IN (_a, _b) AND m.created_at > now() - interval '2 days'
     GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 4
  LOOP
    RAISE NOTICE 'CHAT4701_PEAK|%|%|%', r.who, r.minute, r.n;
  END LOOP;
END
$p$;

ROLLBACK;

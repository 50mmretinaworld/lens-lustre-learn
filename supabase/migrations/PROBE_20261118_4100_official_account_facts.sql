-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_4100 — the official 50mm Retina World account and its chats. READ-ONLY (changes nothing, no names of
-- members printed). Owner 22 Nov 2026: "50mm Retina World messages land in Requests; nobody may block 50mm Retina World."
-- Prints: which profile(s) look like the official account and whether they hold the admin role; how many chats WITH an
-- admin account sit in Requests (for the member side and for the admin side); how many blocks name an admin account.
-- Always ends "FACTS DONE".
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE r record; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'FACTS lane %', current_setting('p32.lane', true);
  FOR r IN SELECT p.id, p.custom_url, public.has_role(p.id, 'admin'::public.app_role) AS is_admin
             FROM public.profiles p
            WHERE p.full_name ILIKE '%50mm%retina%' OR p.custom_url ILIKE '50mm%' LOOP
    RAISE NOTICE 'official-looking profile id=% url=% admin=%', r.id, r.custom_url, r.is_admin;
  END LOOP;
  SELECT count(*) INTO _n FROM public.user_roles ur WHERE ur.role::text = 'admin';
  RAISE NOTICE 'admin role holders: %', _n;
  -- a chat between a member and an admin account: whose row is in Requests?
  SELECT count(*) INTO _n
    FROM public.conversation_members me
    JOIN public.conversation_members other ON other.conversation_id = me.conversation_id AND other.user_id <> me.user_id
   WHERE me.folder = 'requests' AND public.has_role(other.user_id, 'admin'::public.app_role) AND NOT public.has_role(me.user_id, 'admin'::public.app_role);
  RAISE NOTICE 'member rows in Requests for a chat WITH an admin account: %', _n;
  SELECT count(*) INTO _n
    FROM public.conversation_members me
   WHERE me.folder = 'requests' AND public.has_role(me.user_id, 'admin'::public.app_role);
  RAISE NOTICE 'admin-account rows in Requests (members wrote first): %', _n;
  SELECT count(*) INTO _n
    FROM public.conversation_members me
    JOIN public.profiles op ON op.id <> me.user_id
    JOIN public.conversation_members other ON other.conversation_id = me.conversation_id AND other.user_id = op.id
   WHERE me.folder = 'requests' AND (op.full_name ILIKE '%50mm%retina%' OR op.custom_url ILIKE '50mm%');
  RAISE NOTICE 'member rows in Requests for a chat WITH an official-looking profile: %', _n;
  SELECT count(*) INTO _n FROM public.user_blocks b WHERE public.has_role(b.blocked_id, 'admin'::public.app_role);
  RAISE NOTICE 'blocks naming an admin account: %', _n;
  RAISE NOTICE 'FACTS DONE';
END
$p$;

ROLLBACK;

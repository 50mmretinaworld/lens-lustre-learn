-- ═══════════════════════════════════════════════════════════════════════════
-- 20261124_5400 · Messages: the chat list may hold up to 500 chats (was 100). Lanes: staging, production.
--
-- Owner 24 Nov 2026 (screenshot): "in msg box have more than 173 msg but showing a few only". Measured: the app asked
-- for 30 chats and never for more; the server also refused more than 100 per answer. The server's own "_before"
-- paging cannot be used for the next page: it pages by time with "<", and chats that got their last message in the
-- same instant (a broadcast) would be skipped. So the app now asks for MORE from the top (30, then +50 … up to 500)
-- and the server allows up to 500 in one answer.
--
-- HOW: the live definitions are patched IN PLACE — only the cap text `least(greatest(coalesce(_limit, 30), 1), 100)`
-- becomes `…, 500)`, in message_my_conversations and admin_view_inbox. Nothing else in either function is touched
-- (no copy of the body that could drift from what is live). Refused unless the cap text appears exactly once in each.
-- Owner, grants, SECURITY DEFINER and search_path are kept by CREATE OR REPLACE of the same definition.
--
-- Not re-runnable (PRE-002). Rollback: supabase/rollback/20261124_5400_inbox_list_cap_ROLLBACK.sql
-- PROBE: supabase/migrations/PROBE_20261124_5400_inbox_list_cap.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $patch$
DECLARE
  _fn   text;
  _def  text;
  _old  constant text := 'least(greatest(coalesce(_limit, 30), 1), 100)';
  _new  constant text := 'least(greatest(coalesce(_limit, 30), 1), 500)';
  _n    integer;
BEGIN
  FOREACH _fn IN ARRAY ARRAY['public.message_my_conversations(text,integer,timestamptz)',
                             'public.admin_view_inbox(uuid,text,integer,timestamptz)'] LOOP
    IF to_regprocedure(_fn) IS NULL THEN
      RAISE EXCEPTION 'MSG-5400-PRE-001: % is missing', _fn;
    END IF;
    _def := pg_get_functiondef(to_regprocedure(_fn));
    IF position(_new IN _def) > 0 THEN
      RAISE EXCEPTION 'MSG-5400-PRE-002: % already allows 500 — roll back first', _fn;
    END IF;
    _n := (length(_def) - length(replace(_def, _old, ''))) / length(_old);
    IF _n <> 1 THEN
      RAISE EXCEPTION 'MSG-5400-PRE-003: % holds the cap text % times (expected exactly 1) — the live body is not the one this patch was written for', _fn, _n;
    END IF;
    EXECUTE replace(_def, _old, _new);
    RAISE NOTICE 'MSG-5400: % now allows up to 500 chats per answer', _fn;
  END LOOP;
END
$patch$;

DO $post$
BEGIN
  IF position('least(greatest(coalesce(_limit, 30), 1), 500)' IN pg_get_functiondef('public.message_my_conversations(text,integer,timestamptz)'::regprocedure)) = 0
     OR position('least(greatest(coalesce(_limit, 30), 1), 500)' IN pg_get_functiondef('public.admin_view_inbox(uuid,text,integer,timestamptz)'::regprocedure)) = 0
     OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.message_my_conversations(text,integer,timestamptz)'::regprocedure
                      AND prosecdef AND proconfig = ARRAY['search_path=""'])
     OR has_function_privilege('anon', 'public.message_my_conversations(text,integer,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.message_my_conversations(text,integer,timestamptz)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.admin_view_inbox(uuid,text,integer,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'MSG-5400-POST: not as intended';
  END IF;
END
$post$;

COMMIT;

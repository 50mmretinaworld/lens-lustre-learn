-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_3000 — Messages privilege audit. READ-ONLY (changes nothing). Run on staging AND production.
-- Why: three of the Owner's live bugs (photo upload, ...) were one class — a row-security policy calls a function the signed-in
-- member may not run, so the policy itself fails ("permission denied for function"). Earlier PROBEs tested the database
-- door, never the policies as the member. This audit closes the class for good:
--   A1  every policy on the messaging tables, on storage.objects for the message-photos bucket and on realtime.messages:
--       every non-system function it calls must be executable by `authenticated` (and its schema usable)
--   A2  every database function the messages client calls exists, `authenticated` may run it, `anon` may not
--   A3  no message_* / admin_message_* function is executable by `anon` (or PUBLIC)
-- Prints one NOTICE per policy→function dependency as evidence. Ends: "AUDIT PASS" or "AUDIT FAIL (n): …".
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

DO $p$
DECLARE
  _fail text[] := '{}';
  r record;
  _n_pol int := 0; _n_dep int := 0;
  _client_rpcs text[] := ARRAY[
    'admin_view_inbox','admin_view_thread','message_accept_request','message_decline_request','message_mark_delivered',
    'message_mark_read','message_my_conversations','message_peer_status','message_report','message_send','message_send_photo',
    'message_send_reply','message_set_muted','message_thread','message_allowed_me','message_can_reach','message_unread_counts',
    'admin_message_broadcast_audience','admin_message_broadcast_control','admin_message_broadcast_recipients',
    'admin_message_broadcast_report','admin_message_broadcast_save','admin_message_broadcast_send',
    'admin_message_broadcast_withdraw','admin_message_broadcasts','admin_message_member_search','admin_message_report_done',
    'admin_message_reports','admin_message_watchlist','admin_message_word_rules','message_admin_clear_member_rule',
    'message_admin_list_add','message_admin_list_remove','message_admin_set_groups','message_admin_set_member_rule',
    'message_admin_set_mode','message_admin_state','message_admin_word_add','message_admin_word_set_active'
  ];
  _fn text;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'AUDIT lane %', current_setting('p32.lane', true);

  -- A1 — policies → functions
  FOR r IN
    SELECT n.nspname AS sch, c.relname AS tbl, pol.polname AS pol, pol.oid AS pol_oid,
           (pol.polroles = '{0}'::oid[] OR EXISTS (SELECT 1 FROM unnest(pol.polroles) ro(oid) JOIN pg_roles rr ON rr.oid = ro.oid WHERE rr.rolname = 'authenticated')) AS for_auth,
           pg_get_expr(coalesce(pol.polqual, pol.polwithcheck), pol.polrelid) AS expr_sample
      FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE (n.nspname = 'public' AND (c.relname IN ('conversations', 'conversation_members', 'messages') OR c.relname LIKE 'message\_%' ESCAPE '\'))
        OR (n.nspname = 'storage' AND c.relname = 'objects' AND (pol.polname ILIKE '%message%' OR coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') ILIKE '%message-photos%' OR coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') ILIKE '%message-photos%'))
        OR (n.nspname = 'realtime' AND c.relname = 'messages')
     ORDER BY n.nspname, c.relname, pol.polname
  LOOP
    _n_pol := _n_pol + 1;
    IF NOT r.for_auth THEN CONTINUE; END IF;
    FOR _fn IN
      SELECT DISTINCT format('%I.%I(%s)', pn.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) || '|' || p.oid::text
        FROM pg_depend d
        JOIN pg_proc p ON p.oid = d.refobjid
        JOIN pg_namespace pn ON pn.oid = p.pronamespace
       WHERE d.classid = 'pg_policy'::regclass AND d.objid = r.pol_oid AND d.refclassid = 'pg_proc'::regclass
         AND pn.nspname NOT IN ('pg_catalog', 'information_schema')
    LOOP
      _n_dep := _n_dep + 1;
      DECLARE _oid oid := split_part(_fn, '|', 2)::oid; _label text := split_part(_fn, '|', 1);
      BEGIN
        IF NOT has_function_privilege('authenticated', _oid, 'EXECUTE') THEN
          _fail := _fail || format('A1 policy "%s" on %s.%s calls %s — authenticated may NOT execute it', r.pol, r.sch, r.tbl, _label);
        ELSIF NOT has_schema_privilege('authenticated', (SELECT pronamespace FROM pg_proc WHERE oid = _oid), 'USAGE') THEN
          _fail := _fail || format('A1 policy "%s" on %s.%s calls %s — authenticated has no USAGE on its schema', r.pol, r.sch, r.tbl, _label);
        ELSE
          RAISE NOTICE 'A1 ok  %.% policy "%" -> %', r.sch, r.tbl, r.pol, _label;
        END IF;
      END;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'A1 checked % policies, % function calls', _n_pol, _n_dep;
  IF _n_pol = 0 THEN _fail := _fail || 'A1 found no policies at all — the audit query is wrong'; END IF;

  -- A2 — every function the client calls
  FOREACH _fn IN ARRAY _client_rpcs LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = _fn) THEN
      _fail := _fail || ('A2 the client calls ' || _fn || ' but it does not exist');
      CONTINUE;
    END IF;
    FOR r IN SELECT p.oid, pg_get_function_identity_arguments(p.oid) AS args FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = _fn LOOP
      IF NOT has_function_privilege('authenticated', r.oid, 'EXECUTE') THEN
        _fail := _fail || format('A2 %s(%s) cannot be executed by authenticated', _fn, r.args);
      END IF;
    END LOOP;
  END LOOP;

  -- A3 — nothing for anon / PUBLIC
  FOR r IN
    SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND (p.proname LIKE 'message\_%' ESCAPE '\' OR p.proname LIKE 'admin\_message\_%' ESCAPE '\' OR p.proname IN ('admin_view_inbox', 'admin_view_thread'))
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    _fail := _fail || format('A3 anon (signed-out visitor) can execute %s(%s)', r.proname, r.args);
  END LOOP;

  IF array_length(_fail, 1) > 0 THEN
    FOREACH _fn IN ARRAY _fail LOOP RAISE NOTICE 'FINDING: %', _fn; END LOOP;
    RAISE EXCEPTION 'AUDIT FAIL (% finding(s)) — see FINDING lines', array_length(_fail, 1);
  END IF;
  RAISE NOTICE 'AUDIT PASS — % policies, % function calls: every function a policy calls is runnable by members; every client RPC exists, members can run it, signed-out visitors cannot', _n_pol, _n_dep;
END
$p$;

ROLLBACK;

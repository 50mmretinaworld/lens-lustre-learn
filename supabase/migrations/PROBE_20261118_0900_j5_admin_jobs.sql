-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261118_0900 — J5a admin Job Engine reads. One transaction, ROLLBACK.
-- Before 20261118_0900: FAIL (functions missing). After: J5 PASS.
--   P1  a visitor (no login) and a plain member are refused by both functions
--   P2  an admin gets the overview: the three switches, one entry per job kind,
--       counts that match the jobs table
--   P3  the list never returns payload or idempotency key; limit capped at 200;
--       an unknown status is refused
--   P4  both functions are SECURITY DEFINER with an empty search_path
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = notice;

CREATE FUNCTION pg_temp.as_user(_uid uuid, _sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE _v text;
BEGIN
  BEGIN
    IF _uid IS NULL THEN
      PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      SET LOCAL ROLE anon;
    ELSE
      PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
      PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
      SET LOCAL ROLE authenticated;
    END IF;
    EXECUTE _sql INTO _v;
    RAISE EXCEPTION 'PROBE_OK:%', coalesce(_v, '<no row>');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PROBE_OK:%' THEN RETURN 'ok ' || substr(SQLERRM, 10); END IF;
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 80);
  END;
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _admin uuid; _member uuid; _ov jsonb; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'J5 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.admin_jobs_overview()') IS NULL THEN
    RAISE EXCEPTION 'J5 FAIL: admin_jobs_overview missing — expected before 20261118_0900';
  END IF;
  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' ORDER BY r.user_id LIMIT 1;
  SELECT p.id INTO _member FROM public.profiles p
   WHERE NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text <> 'user')
   ORDER BY p.created_at DESC LIMIT 1;

  -- P1
  _r := pg_temp.as_user(NULL, 'SELECT public.admin_jobs_overview()::text');
  IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('P1 visitor overview: ' || _r); END IF;
  _r := pg_temp.as_user(NULL, 'SELECT count(*)::text FROM public.admin_jobs_list()');
  IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('P1 visitor list: ' || _r); END IF;
  IF _member IS NOT NULL THEN
    _r := pg_temp.as_user(_member, 'SELECT public.admin_jobs_overview()::text');
    IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('P1 member overview: ' || _r); END IF;
    _r := pg_temp.as_user(_member, 'SELECT count(*)::text FROM public.admin_jobs_list()');
    IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('P1 member list: ' || _r); END IF;
  END IF;

  -- P2 + P3
  IF _admin IS NULL THEN
    RAISE NOTICE 'J5 note: no admin on this lane — admin path not exercised';
  ELSE
    _r := pg_temp.as_user(_admin, 'SELECT public.admin_jobs_overview()::text');
    IF _r NOT LIKE 'ok %' THEN
      _fail := _fail || ('P2 admin overview: ' || _r);
    ELSE
      _ov := substr(_r, 4)::jsonb;
      IF NOT (_ov->'switches' ? 'job_engine') THEN _fail := _fail || 'P2 switch job_engine missing'::text; END IF;
      IF jsonb_array_length(_ov->'kinds') <> (SELECT count(*) FROM public.job_kinds) THEN
        _fail := _fail || format('P2 %s kinds, want %s', jsonb_array_length(_ov->'kinds'), (SELECT count(*) FROM public.job_kinds));
      END IF;
      SELECT count(*) INTO _n FROM jsonb_array_elements(_ov->'kinds') e
       WHERE (e->>'queued')::int <> (SELECT count(*) FROM public.jobs j WHERE j.kind = e->>'kind' AND j.status = 'queued');
      IF _n > 0 THEN _fail := _fail || format('P2 queued count wrong for %s kind(s)', _n); END IF;
    END IF;
    _r := pg_temp.as_user(_admin, 'SELECT count(*)::text FROM public.admin_jobs_list(NULL, NULL, 100000)');
    IF _r NOT LIKE 'ok %' OR substr(_r, 4)::int > 200 THEN _fail := _fail || ('P3 limit not capped: ' || _r); END IF;
    _r := pg_temp.as_user(_admin, $q$SELECT count(*)::text FROM public.admin_jobs_list('nonsense')$q$);
    IF _r NOT LIKE 'refused 22023%' THEN _fail := _fail || ('P3 unknown status accepted: ' || _r); END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proargnames) a
              WHERE p.oid = 'public.admin_jobs_list(text,text,integer,bigint)'::regprocedure
                AND a IN ('payload', 'idempotency_key')) THEN
    _fail := _fail || 'P3 list returns payload or idempotency key'::text;
  END IF;

  -- P4
  SELECT count(*) INTO _n FROM pg_proc p
   WHERE p.oid IN ('public.admin_jobs_overview()'::regprocedure, 'public.admin_jobs_list(text,text,integer,bigint)'::regprocedure)
     AND p.prosecdef AND p.proconfig @> ARRAY['search_path=""'];
  IF _n <> 2 THEN _fail := _fail || format('P4 %s of 2 functions are DEFINER with empty search_path', _n); END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'J5 FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'J5 FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'J5 PASS (lane %) — admin-only reads; visitors and members refused; no payload; limit capped',
    current_setting('p32.lane', true);
END
$p$;
ROLLBACK;

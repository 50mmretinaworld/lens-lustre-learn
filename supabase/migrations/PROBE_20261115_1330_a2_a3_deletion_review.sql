-- ═══════════════════════════════════════════════════════════════════════════
-- PROBE · 20261115_1330 — A2 + A3. One transaction, ROLLBACK: every request,
-- hold and deletion below (real members are deleted INSIDE the transaction)
-- is thrown away. Before 20261115_1330: FAIL. After: A2 PASS.
--   D1 member's request = no deletion; state deletion_requested, auto-approve in
--      180 days; guard ON → the member can no longer write
--   D2 asking twice → already_requested
--   D3 hold: only an admin, reason required; hold removes the auto-approval
--   D4 a held request is never auto-deleted (job re-checks at run time)
--   D5 a due request: sweep queues one account.delete job + tomorrow's sweep;
--      the job deletes the member: auth user + profile gone, log row 'deleted'
--      (no actor), erasure e-mail queued as a job with no secret in it
--   D6 admin delete: reason required, self-delete refused, instant, logged
--   D7 an admin cannot request their own deletion
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';
SET LOCAL client_min_messages = notice;

CREATE FUNCTION pg_temp.as_user(_uid uuid, _sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE _v text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
    SET LOCAL ROLE authenticated;
    IF _sql ~* '^\s*(insert|update|delete)' AND _sql !~* 'returning' THEN EXECUTE _sql; _v := 'written';
    ELSE EXECUTE _sql INTO _v; END IF;
    RAISE EXCEPTION 'PROBE_OK:%', coalesce(_v, '<no row>');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PROBE_OK:%' THEN RETURN 'ok ' || substr(SQLERRM, 10); END IF;
    RETURN 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 80);
  END;
END
$f$;
-- like as_user, but KEEPS the work (for steps whose effect is checked afterwards)
CREATE FUNCTION pg_temp.as_user_keep(_uid uuid, _sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE _v text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', _uid::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    EXECUTE _sql INTO _v;
  EXCEPTION WHEN OTHERS THEN
    _v := 'refused ' || SQLSTATE || ' ' || left(SQLERRM, 80);
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN _v;
END
$f$;

DO $p$
DECLARE
  _fail text[] := '{}';
  _r text; _m1 uuid; _m2 uuid; _m3 uuid; _admin uuid; s record; _n int;
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'PROBE REFUSED — p32.lane is not asserted';
  END IF;
  RAISE NOTICE 'A2 lane %', current_setting('p32.lane', true);
  IF to_regprocedure('public.account_delete_execute(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'A2 FAIL: account_delete_execute missing — expected before 20261115_1330';
  END IF;

  SELECT r.user_id INTO _admin FROM public.user_roles r WHERE r.role::text = 'admin' ORDER BY r.user_id LIMIT 1;
  SELECT id INTO _m1 FROM (
    SELECT p.id, row_number() OVER (ORDER BY p.created_at DESC) AS rn FROM public.profiles p JOIN auth.users u ON u.id = p.id
     WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false)
       AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id)
       AND NOT EXISTS (SELECT 1 FROM public.account_states a WHERE a.user_id = p.id)) x WHERE rn = 1;
  SELECT id INTO _m2 FROM (
    SELECT p.id, row_number() OVER (ORDER BY p.created_at DESC) AS rn FROM public.profiles p JOIN auth.users u ON u.id = p.id
     WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false)
       AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id)
       AND NOT EXISTS (SELECT 1 FROM public.account_states a WHERE a.user_id = p.id)) x WHERE rn = 2;
  SELECT id INTO _m3 FROM (
    SELECT p.id, row_number() OVER (ORDER BY p.created_at DESC) AS rn FROM public.profiles p JOIN auth.users u ON u.id = p.id
     WHERE NOT p.is_suspended AND NOT coalesce(p.is_banned, false)
       AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id)
       AND NOT EXISTS (SELECT 1 FROM public.account_states a WHERE a.user_id = p.id)) x WHERE rn = 3;
  IF _m1 IS NULL OR _m2 IS NULL OR _m3 IS NULL THEN RAISE EXCEPTION 'A2 FAIL: need three plain members to test with'; END IF;
  UPDATE public.system_flags SET value = true WHERE key IN ('account_state_guard', 'job_engine');

  -- D1
  _r := pg_temp.as_user_keep(_m1, 'SELECT public.request_my_account_deletion()');
  SELECT * INTO s FROM public.account_states WHERE user_id = _m1;
  IF _r <> 'deletion_requested' OR s.state IS DISTINCT FROM 'deletion_requested'
     OR abs(extract(epoch FROM s.auto_approve_at - (now() + interval '180 days'))) > 5
     OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = _m1) THEN
    _fail := _fail || format('D1 request: %s / %s / %s', _r, coalesce(s.state, '-'), coalesce(s.auto_approve_at::text, '-'));
  END IF;
  _r := pg_temp.as_user(_m1, format('UPDATE public.profiles SET full_name = full_name WHERE id = %L', _m1));
  IF _r NOT LIKE 'refused 42501 ACCOUNT_UNDER_REVIEW%' THEN _fail := _fail || ('D1 requester can still write: ' || _r); END IF;
  -- D2
  _r := pg_temp.as_user_keep(_m1, 'SELECT public.request_my_account_deletion()');
  IF _r <> 'already_requested' THEN _fail := _fail || ('D2 second request: ' || _r); END IF;

  -- D3
  _r := pg_temp.as_user(_m2, format($q$SELECT public.admin_decide_deletion(%L, 'hold', 'x')::text$q$, _m1));
  IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('D3 non-admin decided: ' || _r); END IF;
  IF _admin IS NULL THEN
    RAISE NOTICE 'A2 note: no admin on this lane — D3 hold, D6 admin delete not exercised';
  ELSE
    _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_decide_deletion(%L, 'hold', '')::text$q$, _m1));
    IF _r NOT LIKE 'refused 22023%' THEN _fail := _fail || ('D3 hold without a reason: ' || _r); END IF;
    _r := pg_temp.as_user_keep(_admin, format($q$SELECT public.admin_decide_deletion(%L, 'hold', 'A2 probe hold')::text$q$, _m1));
    SELECT * INTO s FROM public.account_states WHERE user_id = _m1;
    IF s.state <> 'under_review' OR s.auto_approve_at IS NOT NULL OR s.deletion_requested_at IS NULL THEN
      _fail := _fail || format('D3 hold: %s / %s / auto %s', _r, s.state, coalesce(s.auto_approve_at::text, 'none'));
    END IF;
  END IF;

  -- D4 held → never auto-deleted (force the clock back to prove it)
  UPDATE public.account_states SET auto_approve_at = NULL WHERE user_id = _m1;
  PERFORM public.account_delete_job(jsonb_build_object('user_id', _m1));
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = _m1) THEN _fail := _fail || 'D4 held member was deleted'::text; END IF;

  -- D5 due request → sweep → job → deletion
  _r := pg_temp.as_user_keep(_m2, 'SELECT public.request_my_account_deletion()');
  UPDATE public.account_states SET auto_approve_at = now() - interval '1 second' WHERE user_id = _m2;
  PERFORM public.account_deletion_sweep('{}'::jsonb);
  IF NOT EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'account.delete' AND idempotency_key = 'account.delete:' || _m2 AND status = 'queued') THEN
    _fail := _fail || 'D5 sweep did not queue the delete job'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'account.deletion_sweep' AND status = 'queued' AND run_at > now()) THEN
    _fail := _fail || 'D5 sweep did not schedule tomorrow'::text;
  END IF;
  _r := public.job_start((SELECT id FROM public.jobs WHERE kind = 'account.delete' AND idempotency_key = 'account.delete:' || _m2));
  IF _r <> 'done' OR EXISTS (SELECT 1 FROM auth.users WHERE id = _m2) OR EXISTS (SELECT 1 FROM public.profiles WHERE id = _m2) THEN
    _fail := _fail || format('D5 delete job: %s; auth user gone %s', _r, NOT EXISTS (SELECT 1 FROM auth.users WHERE id = _m2));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.account_state_log WHERE user_id = _m2 AND to_state = 'deleted' AND actor_id IS NULL) THEN
    _fail := _fail || 'D5 no deleted log row'::text;
  END IF;
  SELECT count(*) INTO _n FROM public.jobs WHERE kind = 'email.account_deleted' AND idempotency_key = 'account-deleted:' || _m2;
  IF _n <> 1 OR EXISTS (SELECT 1 FROM public.jobs WHERE kind = 'email.account_deleted' AND payload::text ~* '"(authorization|apikey|secret|token|password)"') THEN
    _fail := _fail || format('D5 erasure e-mail jobs: %s', _n);
  END IF;

  -- D6 admin delete
  IF _admin IS NOT NULL THEN
    _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_delete_member(%L, '')::text$q$, _m3));
    IF _r NOT LIKE 'refused 22023%' THEN _fail := _fail || ('D6 delete without a reason: ' || _r); END IF;
    _r := pg_temp.as_user(_admin, format($q$SELECT public.admin_delete_member(%L, 'x')::text$q$, _admin));
    IF _r NOT LIKE 'refused 22023%' THEN _fail := _fail || ('D6 admin deleted self: ' || _r); END IF;
    _r := pg_temp.as_user_keep(_admin, format($q$SELECT public.admin_delete_member(%L, 'A2 probe delete')::text$q$, _m3));
    IF EXISTS (SELECT 1 FROM auth.users WHERE id = _m3)
       OR NOT EXISTS (SELECT 1 FROM public.account_state_log WHERE user_id = _m3 AND to_state = 'deleted' AND actor_id = _admin) THEN
      _fail := _fail || ('D6 admin delete: ' || _r);
    END IF;
    -- D7
    _r := pg_temp.as_user(_admin, 'SELECT public.request_my_account_deletion()');
    IF _r NOT LIKE 'refused 42501%' THEN _fail := _fail || ('D7 admin requested own deletion: ' || _r); END IF;
  END IF;

  IF cardinality(_fail) > 0 THEN
    FOREACH _r IN ARRAY _fail LOOP RAISE NOTICE 'A2 FAIL item: %', _r; END LOOP;
    RAISE EXCEPTION 'A2 FAIL (lane %) — % item(s)', current_setting('p32.lane', true), cardinality(_fail);
  END IF;
  RAISE NOTICE 'A2 PASS (lane %) — request = no deletion, 180-day auto-approve, guard blocks; hold = admin-only, reasoned, unlimited; sweep → one job per due member → one delete program, logged, e-mail queued; admin delete instant + reasoned%',
    current_setting('p32.lane', true), CASE WHEN _admin IS NULL THEN ' (no admin on lane: D3/D6/D7 not exercised)' ELSE '' END;
END
$p$;

ROLLBACK;

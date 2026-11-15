-- ROLLBACK · 20261115_1310 · A1 account state + guard
-- Removes the guard from every table, the functions, the two tables and the
-- switch. Members put under review become active again (their log is lost
-- with the table — export it first if the review must be kept).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;
SET LOCAL lock_timeout = '5s';

DO $detach$
DECLARE r record; _n int := 0;
BEGIN
  FOR r IN SELECT c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE t.tgname = 'zz_account_state_guard' AND n.nspname = 'public' LOOP
    EXECUTE format('DROP TRIGGER zz_account_state_guard ON public.%I', r.relname);
    _n := _n + 1;
  END LOOP;
  RAISE NOTICE 'A1 rollback: guard removed from % table(s)', _n;
END
$detach$;

REVOKE ALL ON FUNCTION public.admin_set_account_state(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.my_account_state() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.account_can_act(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.account_state_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.account_state_log_append_only() FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.admin_set_account_state(uuid, text, text);
DROP FUNCTION public.my_account_state();
DROP FUNCTION public.account_state_guard();
DROP TABLE public.account_state_log;
DROP FUNCTION public.account_state_log_append_only();
DROP TABLE public.account_states;
DROP FUNCTION public.account_can_act(uuid);
DELETE FROM public.system_flags WHERE key = 'account_state_guard';

COMMIT;

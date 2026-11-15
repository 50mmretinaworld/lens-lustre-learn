-- ROLLBACK · 20261115_1330 · A2 + A3 deletion review + one delete program
-- Refuses while account.delete / email jobs are waiting or running. Pending
-- member requests stay in account_states (state deletion_requested) and are
-- simply no longer auto-approved.
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.jobs WHERE kind IN ('account.delete', 'email.account_deleted') AND status IN ('queued', 'running')) THEN
    RAISE EXCEPTION 'A2-RB-001: account.delete / email.account_deleted jobs still queued or running';
  END IF;
END
$lane_guard$;

DELETE FROM public.jobs WHERE kind IN ('account.deletion_sweep', 'account.delete', 'email.account_deleted');
DELETE FROM public.job_kinds WHERE kind IN ('account.deletion_sweep', 'account.delete', 'email.account_deleted');

REVOKE ALL ON FUNCTION public.admin_account_state_history(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_list_account_reviews() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.account_deletion_sweep(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.account_delete_job(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_decide_deletion(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_my_account_deletion() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_delete_member(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.account_delete_execute(uuid, uuid, text) FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION public.admin_account_state_history(uuid);
DROP FUNCTION public.admin_list_account_reviews();
DROP FUNCTION public.account_deletion_sweep(jsonb);
DROP FUNCTION public.account_delete_job(jsonb);
DROP FUNCTION public.admin_decide_deletion(uuid, text, text);
DROP FUNCTION public.request_my_account_deletion();
DROP FUNCTION public.admin_delete_member(uuid, text);
DROP FUNCTION public.account_delete_execute(uuid, uuid, text);
ALTER TABLE public.account_state_log DROP CONSTRAINT account_state_log_to_state_chk;

COMMIT;

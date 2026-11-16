-- ROLLBACK · 20261116_1500 · account_can_act back to the 20261115_1310 body
-- (the converter account is stopped by the guard again — turn the guard OFF first
-- on any lane where the media / video worker must keep running).
BEGIN;
DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'APPLY REFUSED — p32.lane is not asserted as staging or production. Dispatch apply-migration.yml.';
  END IF;
END
$lane_guard$;

CREATE OR REPLACE FUNCTION public.account_can_act(_uid uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT _uid IS NULL
      OR (NOT EXISTS (SELECT 1 FROM public.account_states s WHERE s.user_id = _uid AND s.state <> 'active')
          AND NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _uid AND (p.is_suspended OR coalesce(p.is_banned, false))));
$fn$;
REVOKE ALL ON FUNCTION public.account_can_act(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.account_can_act(uuid) TO service_role;
COMMIT;

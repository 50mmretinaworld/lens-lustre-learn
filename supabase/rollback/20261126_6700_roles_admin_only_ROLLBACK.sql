-- ROLLBACK · 20261126_6700. Puts the two member INSERT policies back exactly as they were (live snapshot 17 Oct).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DROP POLICY IF EXISTS "Users can self-assign photographer role" ON public.user_roles;
CREATE POLICY "Users can self-assign photographer role"
  ON public.user_roles FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()) AND role::text = 'registered_photographer');

DROP POLICY IF EXISTS "Users can create applications" ON public.role_applications;
CREATE POLICY "Users can create applications"
  ON public.role_applications FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

COMMIT;

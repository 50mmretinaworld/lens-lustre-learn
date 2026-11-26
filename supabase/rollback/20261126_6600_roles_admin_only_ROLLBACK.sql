-- ROLLBACK · 20261126_6600. Gives members back the two ways in: own 'registered_photographer' role, own application.
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

ALTER POLICY x1_merged_insert ON public.user_roles
  WITH CHECK (public.has_role((SELECT auth.uid()), 'admin'::public.app_role)
              OR (user_id = (SELECT auth.uid()) AND role::text = 'registered_photographer'));

DROP POLICY IF EXISTS x1_merged_insert ON public.role_applications;
CREATE POLICY x1_merged_insert
  ON public.role_applications FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

COMMIT;

-- ROLLBACK · 20261128_7200. Drops admin_search_users_v5. admin_search_users_v4 was never changed; the Users page
-- falls back to it by itself (no app version / last login columns then).
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED — p32.lane reads %.', coalesce(current_setting('p32.lane', true), '(unset)');
  END IF;
END
$lane_guard$;

DROP FUNCTION IF EXISTS public.admin_search_users_v5(text, text, text, text, text, text, text, integer, integer);

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 20261126_6500 · App footer style switch ("floating_footer"). Lanes: staging, production.
-- Owner 26 Nov 2026 (approved sample A): the Android/iPhone apps may show the floating thin footer. Admin →
-- Features → Off / Selected members / All members decides; the apps read it through features_allowed_me (no new
-- build to change it). Created Off: nothing changes for anyone. The website never uses it.
-- Only adds the key to feature_access_feature_check and one row. Rollback: supabase/rollback/…_ROLLBACK.sql
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION
      'APPLY REFUSED — p32.lane reads %. Dispatch apply-migration.yml (it sets p32.lane from target).',
      coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF to_regclass('public.feature_access') IS NULL OR to_regclass('public.feature_access_audit') IS NULL
     OR to_regprocedure('public.features_allowed_me()') IS NULL THEN
    RAISE EXCEPTION 'FF-6500-PRE-001: the feature switch tables or features_allowed_me are missing';
  END IF;
  IF EXISTS (SELECT 1 FROM public.feature_access WHERE feature = 'floating_footer') THEN
    RAISE EXCEPTION 'FF-6500-PRE-002: already applied — roll back first';
  END IF;
END
$pre$;

LOCK TABLE public.feature_access IN ACCESS EXCLUSIVE MODE;

DO $switch$
DECLARE _def text; _keys text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO _def FROM pg_constraint c
   WHERE c.conrelid = 'public.feature_access'::regclass AND c.conname = 'feature_access_feature_check';
  IF _def IS NULL OR _def !~ '^CHECK \(\(feature = ANY \(ARRAY\[''[a-z0-9_]+''::text(, ''[a-z0-9_]+''::text)*\]\)\)\)$' THEN
    RAISE EXCEPTION 'FF-6500-PRE-003: feature_access_feature_check is not a plain key list (read: %)', coalesce(_def, '<none>');
  END IF;
  SELECT array_agg(t.m[1] ORDER BY t.i) INTO _keys
    FROM regexp_matches(_def, '''([a-z0-9_]+)''::text', 'g') WITH ORDINALITY AS t(m, i);
  EXECUTE format(
    'ALTER TABLE public.feature_access DROP CONSTRAINT feature_access_feature_check, '
    'ADD CONSTRAINT feature_access_feature_check CHECK (feature IN (%s))',
    (SELECT string_agg(quote_literal(k), ', ' ORDER BY i)
       FROM unnest(_keys || ARRAY['floating_footer']) WITH ORDINALITY AS u(k, i)));
END
$switch$;

WITH ins AS (
  INSERT INTO public.feature_access (feature, mode) VALUES ('floating_footer', 'off')
  RETURNING feature
)
INSERT INTO public.feature_access_audit (actor, feature, action, old_value, new_value, note)
SELECT NULL, ins.feature, 'mode', NULL, 'off', '20261126_6500: switch created, Off (apps keep the classic footer)'
  FROM ins;

DO $post$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.feature_access WHERE feature = 'floating_footer' AND mode = 'off') THEN
    RAISE EXCEPTION 'FF-6500-POST: the switch is not there, Off' USING ERRCODE = 'raise_exception';
  END IF;
  RAISE NOTICE 'FF-6500: switch floating_footer created Off';
END
$post$;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK · 20261126_6500 floating_footer switch. Lanes: staging, production.
-- Removes the switch, its member list and its key (audited). Apps show the classic footer.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

DO $lane_guard$
BEGIN
  IF coalesce(current_setting('p32.lane', true), '') NOT IN ('staging', 'production') THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED — p32.lane reads %. Dispatch apply-migration.yml (it sets p32.lane from target).',
      coalesce(current_setting('p32.lane', true), '(unset)')
    USING ERRCODE = 'raise_exception';
  END IF;
END
$lane_guard$;

SET LOCAL lock_timeout = '5s';

DO $pre$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.feature_access WHERE feature = 'floating_footer') THEN
    RAISE EXCEPTION 'FF-6500-RB-PRE-001: nothing to roll back';
  END IF;
END
$pre$;

LOCK TABLE public.feature_access IN ACCESS EXCLUSIVE MODE;
DELETE FROM public.feature_access_members WHERE feature = 'floating_footer';
WITH del AS (
  DELETE FROM public.feature_access WHERE feature = 'floating_footer' RETURNING feature, mode
)
INSERT INTO public.feature_access_audit (actor, feature, action, old_value, new_value, note)
SELECT NULL, del.feature, 'mode', del.mode, NULL, '20261126_6500 rollback: switch removed' FROM del;

DO $unkey$
DECLARE _def text; _keys text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO _def FROM pg_constraint c
   WHERE c.conrelid = 'public.feature_access'::regclass AND c.conname = 'feature_access_feature_check';
  IF _def IS NULL OR _def !~ '^CHECK \(\(feature = ANY \(ARRAY\[''[a-z0-9_]+''::text(, ''[a-z0-9_]+''::text)*\]\)\)\)$' THEN
    RAISE EXCEPTION 'FF-6500-RB-PRE-002: feature_access_feature_check is not a plain key list (read: %)', coalesce(_def, '<none>');
  END IF;
  SELECT array_agg(t.m[1] ORDER BY t.i) INTO _keys
    FROM regexp_matches(_def, '''([a-z0-9_]+)''::text', 'g') WITH ORDINALITY AS t(m, i)
   WHERE t.m[1] <> 'floating_footer';
  EXECUTE format(
    'ALTER TABLE public.feature_access DROP CONSTRAINT feature_access_feature_check, '
    'ADD CONSTRAINT feature_access_feature_check CHECK (feature IN (%s))',
    (SELECT string_agg(quote_literal(k), ', ' ORDER BY i) FROM unnest(_keys) WITH ORDINALITY AS u(k, i)));
END
$unkey$;

COMMIT;

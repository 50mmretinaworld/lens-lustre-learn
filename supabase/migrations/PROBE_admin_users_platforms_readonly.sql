-- PROBE (READ ONLY, ends in ROLLBACK) — Owner 28 Nov: "Neil Basu uses App and Web both but showing only Web".
-- Admin → Users showed ONE platform: profiles.last_platform = where the LATEST session was. This counts how many
-- members that hid an app (latest = website but a phone of theirs reported an app version), how many app members
-- never reported a version, and shows the Owner's own row (handle neil.basu) by platform rows only — no tokens.
BEGIN;
SET TRANSACTION READ ONLY;
DO $$
DECLARE
  r record;
  line text := '';
BEGIN
  SELECT
    count(*) FILTER (WHERE p.last_platform = 'web' AND dev.v IS NOT NULL)                     AS web_latest_but_app_known,
    count(*) FILTER (WHERE p.last_platform = 'web' AND dev.v IS NULL AND dev.any_device)        AS web_latest_app_device_no_version,
    count(*) FILTER (WHERE p.last_platform = 'app' AND dev.v IS NULL)                           AS app_without_version,
    count(*) FILTER (WHERE p.last_platform = 'app' AND dev.v IS NOT NULL)                       AS app_with_version,
    count(*) FILTER (WHERE p.last_platform = 'web' AND NOT dev.any_device)                      AS web_only
  INTO r
  FROM public.profiles p
  LEFT JOIN LATERAL (
    SELECT max(t.app_version) FILTER (WHERE t.app_version IS NOT NULL) AS v, count(*) > 0 AS any_device
      FROM public.push_tokens t WHERE t.user_id = p.id
  ) dev ON true;
  RAISE NOTICE 'A · MEMBERS BY PLATFORM: web latest + app version known=% · web latest + app device, no version=% · app, no version=% · app with version=% · web only=%',
    r.web_latest_but_app_known, r.web_latest_app_device_no_version, r.app_without_version, r.app_with_version, r.web_only;

  FOR r IN
    SELECT 'push_tokens' AS src, t.platform::text AS platform, coalesce(t.app_version, '(none)') AS v, t.updated_at AS at
      FROM public.push_tokens t JOIN public.profiles p ON p.id = t.user_id WHERE p.custom_url = 'neil.basu'
    UNION ALL
    SELECT 'push_permission_state', s.platform::text, coalesce(s.app_version, '(none)'), s.updated_at
      FROM public.push_permission_state s JOIN public.profiles p ON p.id = s.user_id WHERE p.custom_url = 'neil.basu'
    ORDER BY 4 DESC LIMIT 12
  LOOP
    line := line || E'\n  ' || rpad(r.src, 22) || rpad(coalesce(r.platform, '?'), 10) || rpad(r.v, 10) || to_char(r.at AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY HH24:MI') || ' IST';
  END LOOP;
  RAISE NOTICE 'B · @neil.basu DEVICES:%', coalesce(nullif(line, ''), E'\n  (no app device recorded)');
END $$;
ROLLBACK;

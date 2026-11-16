-- PROBE · 20261116_0900 — READ ONLY. Who the account guard would lock (look-only)
-- if it were switched ON on this lane: members suspended or banned on their
-- profile, and members in account_states (under review / asked to delete).
-- Exactly the two conditions of public.account_can_act (20261115_1310).
-- Prints name + profile link name only (no e-mail). Changes nothing: ROLLBACK.
BEGIN;
SET TRANSACTION READ ONLY;
DO $p$
DECLARE r record; _n int := 0;
BEGIN
  RAISE NOTICE 'WHO lane % · guard switch now = %', coalesce(current_setting('p32.lane', true), '(unset)'),
    (SELECT value FROM public.system_flags WHERE key = 'account_state_guard');
  FOR r IN
    SELECT p.id, p.full_name, p.custom_url,
           coalesce(p.is_suspended, false) AS suspended, coalesce(p.is_banned, false) AS banned,
           s.state AS review_state, s.set_at
      FROM public.profiles p
      LEFT JOIN public.account_states s ON s.user_id = p.id AND s.state <> 'active'
     WHERE coalesce(p.is_suspended, false) OR coalesce(p.is_banned, false) OR s.user_id IS NOT NULL
     ORDER BY p.full_name
  LOOP
    _n := _n + 1;
    RAISE NOTICE 'WHO % · % (/%) · suspended=% banned=% review=% · id %',
      _n, coalesce(r.full_name, '(no name)'), coalesce(r.custom_url, '-'), r.suspended, r.banned,
      coalesce(r.review_state, '-'), left(r.id::text, 8);
  END LOOP;
  RAISE NOTICE 'WHO total = % member(s) would be look-only with the guard ON', _n;
END $p$;
ROLLBACK;

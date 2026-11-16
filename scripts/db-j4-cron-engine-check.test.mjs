// D1 · J4 · self-test for scripts/db-j4-cron-engine-check.mjs (C-34).
import { judge } from "./db-j4-cron-engine-check.mjs";
let fail = 0;
const ok = (c, w) => { console.log(`  ${c ? "PASS" : "FAIL"}  ${w}`); if (!c) fail = 1; };
const f = (name, text) => ({ name, text });
const probe = (names) => `-- J4-ALLOW-BEGIN\n${names.map((n) => `    '${n}',`).join("\n")}\n-- J4-ALLOW-END`;
const allow = { jobs: { "old-sql": "x" }, outside_git: { "judging-x": "y" }, dynamic_files: { "m/0003.sql": "z" } };
const P = probe(["judging-x", "old-sql"]);
const OLD = f("m/a.sql", "SELECT cron.schedule('old-sql', '* * * * *', $$SELECT public.old_tick();$$);");
const TICK = f("m/b.sql", "SELECT cron.schedule('job-engine-tick', '* * * * *', $cron$SELECT public.job_tick();$cron$);");
const ids = (files, o = {}) => judge({ files, allow: o.allow || allow, base: o.base, probeText: o.probe ?? P }).red.map((r) => r.id).sort().join(",");

console.log("must stay GREEN");
ok(ids([OLD, TICK]) === "", "a frozen SQL job + the engine tick");
ok(ids([OLD, f("m/c.sql", "SELECT cron.schedule('new-job', '0 3 * * *', 'SELECT public.cron_run(''new-job'');');")]) === "", "a new job on cron_run (single-quoted)");
ok(ids([OLD, f("m/c.sql", "SELECT cron.schedule('new-job', '0 3 * * *', $c$SELECT public.cron_run('new-job');$c$);")]) === "", "a new job on cron_run (dollar-quoted)");
ok(ids([OLD, f("m/d.sql", "DO $m$ BEGIN PERFORM cron.schedule(r.job, _sched, format('SELECT public.cron_run(%L);', r.job)); END $m$;")]) === "", "the J3c loop: computed name, command = format(cron_run)");
ok(ids([OLD, f("m/0003.sql", "DO $m$ BEGIN PERFORM cron.schedule(_job, j.schedule, format('SELECT public.cron_http_call(%L);', _job)); END $m$;")]) === "", "the frozen 0003 loop");
ok(ids([OLD, f("m/e.sql", "IF to_regprocedure('cron.schedule(text,text,text)') IS NULL THEN RAISE EXCEPTION 'x'; END IF;")]) === "", "a pre-check that names cron.schedule");
ok(ids([OLD, f("m/e.sql", "SELECT format('SELECT cron.schedule(%L, %L, %L)', j.jobname, j.schedule, j.command) FROM cron.job j;")]) === "", "cron.schedule inside a string literal (archive text)");
ok(ids([OLD, f("m/e.sql", "-- SELECT cron.schedule('hand-job', '* * * * *', 'SELECT 1');")]) === "", "a commented-out job");
ok(ids([OLD], { base: allow }) === "", "base list = this list");
ok(ids([OLD], { base: { jobs: { "old-sql": 1, "gone": 1 }, outside_git: { "judging-x": 1 }, dynamic_files: { "m/0003.sql": 1 } } }) === "", "the list shrank against base");

console.log("must be RED");
ok(ids([OLD, f("m/c.sql", "SELECT cron.schedule('new-job', '0 3 * * *', 'SELECT public.new_job();');")]) === "R1", "R1 a new SQL job outside the engine");
ok(ids([OLD, f("m/c.sql", "SELECT cron.schedule('new-job', '0 3 * * *', 'SELECT public.cron_http_call(''new-job'');');")]) === "R1", "R1 a new cron_http_call job");
ok(ids([OLD, f("m/c.sql", "SELECT cron.schedule('new-job', '0 3 * * *', 'SELECT public.cron_run(''other'');');")]) === "R1", "R1 cron_run of a different name");
ok(ids([OLD, f("m/c.sql", "SELECT cron.schedule('old-sql', '* * * * *', 'SELECT public.cron_run(''old-sql'');');")]) === "R2", "R2 a frozen job moved onto the engine but still listed");
ok(ids([OLD, f("m/c.sql", "SELECT cron.unschedule('old-sql');")]) === "R2", "R2 a frozen job unscheduled but still listed");
ok(ids([OLD, f("m/d.sql", "DO $m$ BEGIN PERFORM cron.schedule(_n, '* * * * *', 'SELECT public.x()'); END $m$;")]) === "R3", "R3 computed arguments in a new file");
ok(ids([OLD, f("m/d.sql", "SELECT cron.alter_job(5, command := 'SELECT 1');")]) === "R4", "R4 cron.alter_job");
ok(ids([OLD], { base: { jobs: {}, outside_git: { "judging-x": 1 }, dynamic_files: { "m/0003.sql": 1 } } }) === "R5", "R5 an entry added to the allow-list");
ok(ids([OLD], { base: { jobs: { "old-sql": 1 }, outside_git: { "judging-x": 1 }, dynamic_files: {} } }) === "R5", "R5 a dynamic file added");
ok(ids([OLD], { probe: probe(["old-sql"]) }) === "R6", "R6 the live PROBE list misses a name");
ok(ids([OLD], { probe: "" }) === "R6", "R6 the live PROBE has no list");
console.log(fail ? "\nSOME CASES FAILED" : "\nALL CASES PASS"); process.exit(fail);

// ═══════════════════════════════════════════════════════════════════════════
// D1 · J4 · THE CRON-ENGINE RATCHET — a new scheduled job goes through the job
// engine (Job Engine plan, Part 1 · J4; Owner "go" 15 Nov 2026).
//
// Every cron.schedule in an applied migration is read in apply order
// (UNAPPLIED_* and PROBE_* skipped; the last command per job name counts,
// cron.unschedule forgets it — the same reader as the P9 check). Green shapes:
//   · SELECT public.cron_run('<the same job name>');   (the engine entry)
//   · job-engine-tick → SELECT public.job_tick();       (the engine itself)
//   · a job named in scripts/db-j4-cron-engine-allow.json "jobs" (frozen 16 Nov)
// RED:
//   R1 · a cron job outside the engine that is not on the allow-list
//   R2 · an allow-list entry that is stale: no such job in git any more, or it
//        now runs through cron_run — remove the line (the list only shrinks)
//   R3 · a cron.schedule whose arguments are not plain literals (a loop or
//        format()), outside the frozen "dynamic_files", unless its command is
//        format('SELECT public.cron_run(%L);', …)
//   R4 · cron.alter_job — it changes a job's command or schedule unseen
//   R5 · an allow-list entry ADDED compared with the base branch (--base <json>)
//   R6 · the names embedded in PROBE_j4_cron_engine_live.sql differ from the
//        allow-list (the live half must check the same list)
// READ-ONLY. Usage: node scripts/db-j4-cron-engine-check.mjs [root] [--base <allow.json>]
// Exit: 0 pass · 1 red · 2 error. Self-test: scripts/db-j4-cron-engine-check.test.mjs
// ═══════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { scan, loadTree } from "./db-p9-cron-http-check.mjs";
import { stripComments } from "./db-p5-cron-cadence-check.mjs";

export const ALLOW_PATH = "scripts/db-j4-cron-engine-allow.json";
export const PROBE_PATH = "supabase/migrations/PROBE_j4_cron_engine_live.sql";
const LITERAL_RE = /cron\.schedule\s*\(\s*'[^']+'\s*,\s*'[^']*'\s*,\s*('(?:[^']|'')*'|\$([A-Za-z_][A-Za-z0-9_]*)?\$[\s\S]*?\$\2\$)/gi;
// a real call: SELECT/PERFORM cron.schedule( not inside a string literal (format('SELECT cron.schedule(…') )
const CALL_RE = /(^|[^'A-Za-z0-9_])(SELECT|PERFORM)\s+cron\s*\.\s*schedule\s*\(/gi;
const ALTER_RE = /\bcron\s*\.\s*alter_job\s*\(/i;
const ENGINE_FORMAT_RE = /^\s*(SELECT|PERFORM)\s+cron\s*\.\s*schedule\s*\([^;]*?format\s*\(\s*'SELECT public\.cron_run\(%L\);'/i;

export function onEngine(job, command) {
  const c = command.replace(/\s+/g, " ").trim();
  if (c.toLowerCase() === `select public.cron_run('${job}');`.toLowerCase()) return true;
  return job === "job-engine-tick" && /^select public\.job_tick\(\);?$/i.test(c);
}

export function dynamicCalls(files) {
  const out = [];
  for (const { name, text } of files) {
    const sql = stripComments(text);
    const literalAt = new Set([...sql.matchAll(LITERAL_RE)].map((m) => m.index));
    for (const m of sql.matchAll(CALL_RE)) {
      const at = m.index + m[1].length;
      const callAt = sql.toLowerCase().indexOf("cron", at);
      const literal = [...literalAt].some((i) => i === callAt);
      if (literal) continue;
      out.push({ file: name, engine: ENGINE_FORMAT_RE.test(sql.slice(at, at + 400)) });
    }
    if (ALTER_RE.test(sql)) out.push({ file: name, alter: true });
  }
  return out;
}

export function probeNames(text) {
  const m = /-- J4-ALLOW-BEGIN([\s\S]*?)-- J4-ALLOW-END/.exec(text || "");
  return m ? [...m[1].matchAll(/'([a-z0-9][a-z0-9-]*)'/g)].map((x) => x[1]).sort() : null;
}

export function judge({ files, allow, base, probeText }) {
  const red = [];
  const jobs = scan(files);
  const listed = new Set(Object.keys(allow.jobs || {}));
  const outside = new Set(Object.keys(allow.outside_git || {}));
  const dyn = new Set(Object.keys(allow.dynamic_files || {}));
  for (const [job, v] of jobs) {
    if (onEngine(job, v.command)) {
      if (listed.has(job)) red.push({ id: "R2", job, what: "now runs through cron_run — remove it from the allow-list" });
    } else if (!listed.has(job)) {
      red.push({ id: "R1", job, what: `outside the job engine (${v.file}) — schedule SELECT public.cron_run('${job}'); with a cron.${job} job kind` });
    }
  }
  for (const job of listed) if (!jobs.has(job)) red.push({ id: "R2", job, what: "allow-list entry with no such cron job in git — remove it" });
  for (const d of dynamicCalls(files)) {
    if (d.alter) red.push({ id: "R4", job: "-", what: `cron.alter_job in ${d.file}` });
    else if (!d.engine && !dyn.has(d.file)) red.push({ id: "R3", job: "-", what: `cron.schedule with computed arguments in ${d.file} that is not format('SELECT public.cron_run(%L);', …)` });
  }
  if (base) {
    const before = new Set([...Object.keys(base.jobs || {}), ...Object.keys(base.outside_git || {})]);
    for (const job of [...listed, ...outside]) if (!before.has(job)) red.push({ id: "R5", job, what: "added to the allow-list — new jobs go through the engine" });
    for (const f of dyn) if (!Object.keys(base.dynamic_files || {}).includes(f)) red.push({ id: "R5", job: "-", what: `dynamic file ${f} added to the allow-list` });
  }
  const want = [...listed, ...outside].sort();
  const got = probeNames(probeText);
  if (!got) red.push({ id: "R6", job: "-", what: `${PROBE_PATH} has no J4-ALLOW-BEGIN/END list` });
  else if (got.join(",") !== want.join(",")) {
    const miss = want.filter((x) => !got.includes(x)), extra = got.filter((x) => !want.includes(x));
    red.push({ id: "R6", job: "-", what: `live PROBE list differs from the allow-list (missing: ${miss.join(" ") || "-"}; extra: ${extra.join(" ") || "-"})` });
  }
  return { jobs, red };
}

function main() {
  const args = process.argv.slice(2);
  const bi = args.indexOf("--base");
  const basePath = bi >= 0 ? args[bi + 1] : null;
  const root = args.find((a, i) => !a.startsWith("--") && (bi < 0 || i !== bi + 1)) || join(fileURLToPath(new URL(".", import.meta.url)), "..");
  let files, allow, base = null, probeText = "";
  try {
    files = loadTree(root);
    allow = JSON.parse(readFileSync(join(root, ALLOW_PATH), "utf8"));
    if (basePath && existsSync(basePath) && readFileSync(basePath, "utf8").trim()) base = JSON.parse(readFileSync(basePath, "utf8"));
    if (existsSync(join(root, PROBE_PATH))) probeText = readFileSync(join(root, PROBE_PATH), "utf8");
  } catch (e) { console.error("ERROR: " + e.message); process.exit(2); }
  const { jobs, red } = judge({ files, allow, base, probeText });
  console.log("D1 · J4 cron-engine ratchet — new scheduled jobs go through the job engine");
  console.log(`read ${files.length} applied migration file(s); ${jobs.size} literal cron job(s); allow-list ${Object.keys(allow.jobs || {}).length} + ${Object.keys(allow.outside_git || {}).length} outside git; base ${base ? "compared" : "not given"}`);
  for (const [job, v] of [...jobs].sort()) console.log(`  ${onEngine(job, v.command) ? "engine " : "allowed"}  ${job}  [${v.schedule}]`);
  for (const r of red) console.log(`  ${r.id}  ${r.job}: ${r.what}`);
  if (red.length) { console.log(`FAIL — ${red.length} item(s). A new scheduled job = SELECT public.cron_run('<job>'); plus a cron.<job> job kind.`); process.exit(1); }
  console.log("PASS — every cron job in git is on the engine or on the frozen allow-list");
}
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main();

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  EMPTY_DRAFT, audienceLabel, broadcastToDraft, draftFields, parseAudienceCount, parseBroadcasts,
} from "@/hooks/admin/usePushCentre";

/**
 * CONTRACT — the admin page and 20261116_1500 must name the same functions,
 * arguments and columns. A renamed column would not fail a build: the page
 * would show 0 / "—" and look fine.
 */
const SQL = readFileSync(join(process.cwd(), "supabase/migrations/20261116_1500_push_centre.sql"), "utf8");
const HOOK = readFileSync(join(process.cwd(), "src/hooks/admin/usePushCentre.ts"), "utf8");
const EDGE = readFileSync(join(process.cwd(), "supabase/functions/send-broadcast-push/index.ts"), "utf8");

/** Argument names of `CREATE FUNCTION public.<name>(...)`. */
function sqlArgs(name: string): string[] {
  const m = new RegExp(`CREATE FUNCTION public\\.${name}\\(([^)]*)\\)`).exec(SQL);
  if (!m) throw new Error(`${name} is not created by 1500`);
  return m[1].split(",").map((a) => a.trim().split(/\s+/)[0]).filter(Boolean);
}

/** Column names of that function's RETURNS TABLE (...). */
function sqlColumns(name: string): string[] {
  const at = SQL.indexOf(`CREATE FUNCTION public.${name}(`);
  const m = /RETURNS TABLE \(([\s\S]*?)\)\s*LANGUAGE/.exec(SQL.slice(at));
  if (at < 0 || !m) throw new Error(`${name} has no RETURNS TABLE`);
  return m[1].split(",").map((c) => c.trim().split(/\s+/)[0]).filter(Boolean);
}

/** Every `.rpc("name" …, { _a: …, _b: … }` call in a source file → name → argument names. */
function rpcCalls(src: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  const re = /\.rpc\("([a-z_]+)"(?: as never)?,\s*\{([^}]*)\}/g;
  for (let m = re.exec(src); m; m = re.exec(src)) {
    out.set(m[1], [...m[2].matchAll(/(_[a-z_]+)\s*:/g)].map((x) => x[1]));
  }
  return out;
}

describe("page ↔ SQL (20261116_1500)", () => {
  it("every function the page calls exists with exactly those argument names", () => {
    const calls = rpcCalls(HOOK);
    expect([...calls.keys()].sort()).toEqual([
      "admin_push_audience", "admin_push_broadcast_cancel", "admin_push_broadcast_delete",
      "admin_push_broadcast_save", "admin_push_broadcast_schedule", "admin_push_broadcasts",
    ]);
    for (const [name, args] of calls) expect(sqlArgs(name), name).toEqual(args);
  });

  it("every function the sender calls exists with those argument names", () => {
    const calls = rpcCalls(EDGE);
    expect([...calls.keys()].sort()).toEqual(["push_broadcast_claim", "push_broadcast_finish", "push_broadcast_targets"]);
    for (const [name, args] of calls) expect(sqlArgs(name), name).toEqual(args);
  });

  it("the audience count reads every column the SQL returns, and nothing else", () => {
    const cols = sqlColumns("admin_push_audience");
    const row = Object.fromEntries(cols.map((c, i) => [c, c === "scheduling_on" ? true : i + 1]));
    const parsed = parseAudienceCount([row]);
    expect(Object.keys(parsed ?? {}).sort()).toEqual([...cols].sort());
    for (const c of cols) expect((parsed as unknown as Record<string, unknown>)[c], c).toBe(row[c]);
  });

  it("the lists read every column the SQL returns", () => {
    const cols = sqlColumns("admin_push_broadcasts").filter((c) => c !== "total_count");
    const row: Record<string, unknown> = Object.fromEntries(cols.map((c) => [c, `v-${c}`]));
    Object.assign(row, {
      id: 7, kind: "message", status: "sent", stuck: true, images: ["https://x/1.webp"], actions: [{ label: "Go", link: "/feed" }],
      audience: { kind: "all" }, audience_members: 9, reached_members: 8, devices: 7, delivered: 6, failed: 1, removed: 1,
      opened: 3, fail_reasons: { "404 UNREGISTERED": 1 }, total_count: 41,
    });
    const { items, total } = parseBroadcasts([row]);
    expect(total).toBe(41);
    expect(Object.keys(items[0]).sort()).toEqual([...cols].sort());
    for (const c of cols) expect(items[0][c as keyof (typeof items)[0]], c).toEqual(row[c]);
  });

  it("a draft sends exactly the fields admin_push_broadcast_save reads", () => {
    const read = [...new Set([...SQL.slice(SQL.indexOf("CREATE FUNCTION public.admin_push_broadcast_save(")).split("$fn$;")[0]
      .matchAll(/_fields->>?'([a-z_]+)'/g)].map((m) => m[1]))].sort();
    expect(Object.keys(draftFields(EMPTY_DRAFT)).sort()).toEqual(read);
  });

  it("the audience kinds the page offers are the ones push_audience_check accepts", () => {
    const body = SQL.slice(SQL.indexOf("CREATE FUNCTION public.push_audience_check("), SQL.indexOf("CREATE FUNCTION public.push_audience_members("));
    const kinds = [...body.matchAll(/k = '([a-z]+)'/g)].map((m) => m[1]).sort();
    expect(kinds).toEqual(["active", "all", "badge", "members", "role"]);
    expect(audienceLabel({ kind: "all" })).toBe("Everyone");
    expect(audienceLabel({ kind: "active", days: 7 })).toBe("Active in the last 7 days");
    expect(audienceLabel({ kind: "members", ids: ["a"] })).toBe("1 chosen member");
  });
});

describe("parsers never invent numbers", () => {
  it("empty or broken answers become empty lists / null, not zeros that look real", () => {
    expect(parseAudienceCount([])).toBeNull();
    expect(parseAudienceCount(null)).toBeNull();
    expect(parseBroadcasts(null)).toEqual({ items: [], total: 0 });
  });

  it("a history row copied as a new message keeps the content and drops the id", () => {
    const { items } = parseBroadcasts([{ id: 5, kind: "message", status: "sent", title: "T", body: "B", link: "/feed", images: [], actions: [], audience: { kind: "active", days: 30 } }]);
    const d = broadcastToDraft(items[0], true);
    expect(d).toMatchObject({ id: null, kind: "message", title: "T", body: "B", link: "/feed", audience: { kind: "active", days: 30 } });
  });
});

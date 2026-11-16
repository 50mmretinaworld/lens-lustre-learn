import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseFacets, parseMembers, MEMBER_STATUSES } from "../useAdminMembers";

const root = join(__dirname, "..", "..", "..", "..");
const sql = readFileSync(join(root, "supabase", "migrations", "20261116_1400_admin_users_v4.sql"), "utf8");
const hook = readFileSync(join(root, "src", "hooks", "admin", "useAdminMembers.ts"), "utf8");

describe("Admin Users table ↔ 20261116_1400 contract", () => {
  it("the client calls the two functions the migration creates, with its argument names", () => {
    for (const fn of ["admin_search_users_v4", "admin_user_facets"]) {
      expect(sql).toContain(`CREATE FUNCTION public.${fn}(`);
      expect(hook).toContain(`"${fn}"`);
    }
    for (const arg of ["_query", "_role", "_badge", "_platform", "_status", "_active", "_sort", "_limit", "_offset"]) {
      expect(hook).toContain(arg);
      expect(sql).toMatch(new RegExp(`\\b${arg}\\s+(text|integer)`));
    }
  });

  it("every status the client knows is one the SQL can return, and the facet columns match", () => {
    for (const s of MEMBER_STATUSES) expect(sql).toContain(`'${s}'`);
    for (const c of ["all_count", "active_count", "suspended_count", "banned_count", "under_review_count",
      "deletion_requested_count", "platform_all_count", "app_count", "web_count", "unknown_count"]) {
      expect(sql).toContain(c);
      expect(hook).toContain(c);
    }
  });
});

describe("parseMembers / parseFacets", () => {
  it("keeps good rows, drops malformed ones, reads total_count and defaults an unknown status to active", () => {
    const out = parseMembers([
      { id: "a", created_at: "2026-11-01T00:00:00Z", status: "banned", roles: ["user", 3], badges: null, last_platform: "app", total_count: "42" },
      { id: 7, created_at: "x" },
      { id: "b", created_at: "2026-11-02T00:00:00Z", status: "weird", last_platform: "tv" },
    ]);
    expect(out.total).toBe(42);
    expect(out.rows.map((r) => [r.id, r.status, r.last_platform])).toEqual([["a", "banned", "app"], ["b", "active", null]]);
    expect(out.rows[0].roles).toEqual(["user"]);
    expect(out.rows[0].badges).toEqual([]);
    expect(parseMembers(null)).toEqual({ rows: [], total: 0 });
  });

  it("reads one facets row", () => {
    const f = parseFacets([{ all_count: 10, active_count: 6, suspended_count: 2, banned_count: 1, under_review_count: 1, deletion_requested_count: 0, platform_all_count: 10, app_count: 5, web_count: 3, unknown_count: 2 }]);
    expect(f?.status).toEqual({ all: 10, active: 6, suspended: 2, banned: 1, under_review: 1, deletion_requested: 0 });
    expect(f?.platform).toEqual({ all: 10, app: 5, web: 3, unknown: 2 });
    expect(parseFacets([])).toBeNull();
  });
});

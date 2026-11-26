/**
 * ROLES AND BADGES ARE AN HONOUR (Owner, 26 Nov 2026) — RATCHET.
 *
 * No member gives themselves a role or a badge, and nobody requests one: only an
 * admin grants. The database refuses it (20261126_6700); this stops a screen
 * that offers it from coming back. A new writer has to be an ADMIN screen and be
 * added here on purpose.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { stripComments } from "@/test-utils/sourceText";

const ADMIN_WRITERS = [
  "src/components/admin/AdminRoleApplications.tsx",
  "src/components/admin/AdminUsers.tsx",
  "src/hooks/admin/useAdminMembers.ts",
];

const WRITE = /from\(\s*["'](user_roles|user_badges|role_applications)["'][^)]*\)[^;]{0,120}?\.(insert|upsert|update|delete)\(/;

function sources(dir: string): string[] {
  return readdirSync(join(process.cwd(), dir), { withFileTypes: true }).flatMap((e) => {
    const rel = `${dir}/${e.name}`;
    if (e.isDirectory()) return e.name === "__tests__" || e.name === "integrations" ? [] : sources(rel);
    return /\.tsx?$/.test(e.name) && !/\.test\./.test(e.name) ? [rel] : [];
  });
}

describe("only an admin writes roles, badges or role requests", () => {
  const writers = sources("src").filter((f) => WRITE.test(stripComments(readFileSync(f, "utf8"))));

  it("no screen outside the admin writers does", () => {
    expect(writers.filter((f) => !ADMIN_WRITERS.includes(f))).toEqual([]);
  });

  it("positive control: the sweep sees the admin writers", () => {
    expect(writers.sort()).toEqual([...ADMIN_WRITERS].sort());
  });
});

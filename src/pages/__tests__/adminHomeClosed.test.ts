/**
 * Owner 24 Nov 2026: "when click admin, /admin must open with all menus closed — why does Health open?"
 * Bare /admin is the admin home: no forward to the first section, no section selected (so every menu group,
 * which opens only for its active section, stays closed), and the layout's access guard lets the home through.
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const panel = readFileSync(join(process.cwd(), "src/pages/AdminPanel.tsx"), "utf8");
const layout = readFileSync(join(process.cwd(), "src/components/admin/AdminLayout.tsx"), "utf8");

describe("bare /admin is the admin home, every menu closed", () => {
  it("the forward to the first section never fires for bare /admin", () => {
    expect(panel).toMatch(/const atHome = rawRoute === "";/);
    expect(panel).toMatch(/hasAdminPanelAccess &&\s*!atHome &&/);
    expect(panel).not.toMatch(/\(!rawRoute \|\| !VALID_ROUTES\.has\(rawRoute\)/);
  });
  it("the home renders with no section selected", () => {
    expect(panel).toMatch(/if \(atHome\) \{[\s\S]{0,200}<AdminLayout currentRoute=""/);
    expect(panel).toContain('data-testid="admin-home"');
  });
  it("a menu group opens only for its own active section", () => {
    expect(layout).toMatch(/const isGroupActive = filteredItems\.some\(\(item\) => item\[0\] === currentRoute\);/);
  });
  it("the access guard lets the home through", () => {
    expect(layout).toMatch(/currentRoute !== "" && !canAccessTab\(adminSubRoles, currentRoute as AdminTab\)/);
  });
});

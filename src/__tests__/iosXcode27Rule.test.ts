/**
 * Owner order 27 Nov 2026: every iOS build and update uses Xcode 27 or newer — no exceptions
 * (docs/IOS_APP_STORE_RULES.md rule 8, Apple notice ITMS-90725). This fails if a workflow goes back.
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const dir = join(process.cwd(), ".github", "workflows");
// ios-app-review.yml only talks to App Store Connect (no compile); every other ios-*.yml builds.
const builders = readdirSync(dir).filter((f) => /^ios-.*\.yml$/.test(f) && f !== "ios-app-review.yml");
const code = (f: string) =>
  readFileSync(join(dir, f), "utf8").split(/\r?\n/).filter((l) => !/^\s*#/.test(l)).join("\n");

describe("iOS builds use Xcode 27", () => {
  it("covers the build workflow", () => {
    expect(builders).toContain("ios-build.yml");
  });

  it.each(builders)("%s runs on the Xcode 27 machine only", (f) => {
    const runsOn = [...code(f).matchAll(/^\s*runs-on:\s*([^#\n]+)/gm)].map((m) => m[1].trim());
    expect(runsOn.length).toBeGreaterThan(0);
    expect(runsOn.filter((r) => r !== "xcode-27")).toEqual([]);
  });

  it("ios-build.yml pins Xcode 27 and offers no other version", () => {
    const pins = [...code("ios-build.yml").matchAll(/xcode-version:\s*(.+)$/gm)].map((m) => m[1].trim());
    expect(pins).toEqual(["'27.0'"]);
  });

  it("the written rule is in the iOS rule book", () => {
    expect(readFileSync(join(process.cwd(), "docs", "IOS_APP_STORE_RULES.md"), "utf8")).toContain("Xcode 27 only");
  });
});

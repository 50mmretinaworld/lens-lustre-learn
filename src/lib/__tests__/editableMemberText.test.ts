/**
 * Editing stored member text (Owner 18 Nov 2026: no @[...] anywhere, from the root).
 * An editor opens "@Name" with the profile's CURRENT name, never @[Name](id), and
 * untouched names turn back into the same tags on save.
 */
import { describe, it, expect, vi } from "vitest";

const A = "11111111-1111-4111-8111-111111111111"; // renamed since the tag was written
const B = "22222222-2222-4222-8222-222222222222"; // profile gone
const C = "33333333-3333-4333-8333-333333333333"; // same visible name as D
const D = "44444444-4444-4444-8444-444444444444";

vi.mock("@/lib/profileMapCache", () => ({
  fetchProfileMap: async (ids: string[]) =>
    new Map(ids.flatMap((id) =>
      id === A ? [[id, { id, full_name: "Sri V R Narayanaswamy", custom_url: "sri" }]]
      : id === C || id === D ? [[id, { id, full_name: "Ravi Kumar", custom_url: null }]]
      : [])),
}));

import { loadEditableText, storedFromEditable } from "@/lib/editableMemberText";

describe("editableMemberText", () => {
  it("opens with the profile's current name, never the stored form", async () => {
    const e = await loadEditableText(`Thanks @[Sri V R Narayanasw](${A}) and @[Old Friend](${B}) @[@all](all) 🙏`);
    expect(e.text).toBe("Thanks @Sri V R Narayanaswamy and @Old Friend @all 🙏");
    expect(e.text).not.toContain("@[");
  });

  it("untouched names go back to tags (same ids); the renamed member carries the current name", async () => {
    const stored = `Thanks @[Sri V R Narayanasw](${A}) and @[Old Friend](${B}) @[@all](all) 🙏`;
    const e = await loadEditableText(stored);
    expect(storedFromEditable(`${e.text} great shot`, e.picks)).toBe(
      `Thanks @[Sri V R Narayanaswamy](${A}) and @[Old Friend](${B}) @[all](all) 🙏 great shot`,
    );
  });

  it("@all still matches the server's rule after a round trip", async () => {
    const e = await loadEditableText("@[@all](all) its the time");
    expect(storedFromEditable(e.text, e.picks)).toMatch(/@\[[^\]]*\]\(all\)/);
  });

  it("one visible name for two different members: neither is converted back (never a wrong tag)", async () => {
    const e = await loadEditableText(`@[Ravi](${C}) and @[Ravi K](${D})`);
    expect(e.text).toBe("@Ravi Kumar and @Ravi Kumar");
    expect(storedFromEditable(e.text, e.picks)).toBe("@Ravi Kumar and @Ravi Kumar");
  });

  it("text without tags is untouched", async () => {
    const e = await loadEditableText("Golden hour 🌅");
    expect(e).toEqual({ text: "Golden hour 🌅", picks: [] });
  });
});

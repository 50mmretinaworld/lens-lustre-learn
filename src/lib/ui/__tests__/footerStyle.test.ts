/** The app footer style (Owner 26 Nov 2026, sample A): the classic bar is unchanged; floating only in the apps. */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { footerClasses, homePulse } from "@/lib/ui/footerStyle";

const read = (p: string) => readFileSync(join(process.cwd(), p), "utf8");

describe("footer classes", () => {
  it("classic is exactly the old bar", () => {
    const c = footerClasses(false, false);
    expect(c.nav).toBe("fixed bottom-0 left-0 right-0 z-50 bg-card/60 backdrop-blur-2xl backdrop-saturate-150 border-t border-border/25 lg:hidden safe-area-bottom");
    expect(c.row.trim()).toBe("flex items-center justify-around px-1 relative h-12");
    expect(c.homeDisc).toBe("h-12 w-12");
    expect(c.avatar).toBe("h-7 w-7");
  });

  it("floating: thin, soft corners (not a pill), smaller while scrolling down, logo still raised", () => {
    const full = footerClasses(true, false);
    const small = footerClasses(true, true);
    expect(full.row).toContain("h-[44px]");
    expect(small.row).toContain("h-[36px]");
    expect(full.nav).toContain("rounded-[14px]");
    expect(small.nav).toContain("rounded-[12px]");
    expect(full.nav + small.nav).not.toContain("rounded-full");
    expect(full.homeLink).toContain("-mt-6");
    expect(small.homeLink).toContain("-mt-5");
  });

  it("the 50mm button beats like a heart when floating, and stays still on reduced motion", () => {
    expect(homePulse(true, false).disc).toHaveProperty("y");
    expect(homePulse(true, false).transition.duration).toBeLessThan(2);
    expect(homePulse(false, false).disc).toEqual({ scale: [1, 1.08, 1] });
    expect(homePulse(true, true).disc).toEqual({});
  });
});

describe("one switch, apps only", () => {
  it("floating needs the admin switch AND the installed app", () => {
    const src = read("src/lib/ui/footerStyle.ts");
    expect(src).toContain('useFeatureAllowed("floating_footer")');
    expect(src).toContain("allowed && isNativeCapacitorApp()");
  });
  it("the bar takes its look from this module only", () => {
    const nav = read("src/components/MobileBottomNav.tsx");
    expect(nav).toContain("footerClasses(floating, compact)");
    expect(nav).not.toContain("bg-card/60 backdrop-blur-2xl");
  });
});

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { FEATURE_INFO, parseFeatureState } from "@/lib/admin/featureSwitches";

const root = process.cwd();
const read = (p: string) => readFileSync(join(root, p), "utf8");

describe("Feed order switch (20261123_4600, Owner 2026-11-23 'Admin switch')", () => {
  it("is named in the Owner's words", () => {
    expect(FEATURE_INFO.feed_newest_first.title).toBe("Feed order: Newest first");
    expect(FEATURE_INFO.feed_newest_first.blurb).toMatch(/Fair mix/);
  });

  it("the server's row is shown, not dropped as unknown", () => {
    const s = parseFeatureState([{ feature: "feed_newest_first", mode: "off", members: [], history: [] }]);
    expect(s.map((x) => x.feature)).toEqual(["feed_newest_first"]);
  });

  it("has its own Admin route that renders the switch", () => {
    const panel = read("src/pages/AdminPanel.tsx");
    expect(panel).toMatch(/\["feed_order", "Feed Order", Sparkles\]/);
    expect(panel).toMatch(/currentRoute === "feed_order" && <LazyTab><AdminVideoFeature feature="feed_newest_first" \/><\/LazyTab>/);
  });

  it("the server decides: get_feed_page checks the switch for the caller, created Off", () => {
    const sql = read("supabase/migrations/20261123_4600_feed_newest_first_switch.sql");
    expect(sql).toMatch(/IF _tab = 'for_you' AND public\.feature_allowed\('feed_newest_first', _me\) THEN/);
    expect(sql).toMatch(/INSERT INTO public\.feature_access \(feature, mode\) VALUES \('feed_newest_first', 'off'\)/);
  });

  it("a newest-first page is never reordered on the device", () => {
    const q = read("src/hooks/feed/useFeedQuery.ts");
    expect(q).toMatch(/servedPersonal \|\| timeline \|\| newestFirstServed \? enriched : reorderNoBackToBack/);
  });
});

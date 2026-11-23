import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { latestPerScreen, LIMIT_P50, LIMIT_P95 } from "@/components/admin/AdminScreenSpeed";

const r = (day: string, screen: string, platform: string, p50: number, cold = false) =>
  ({ day, screen, cold, platform, n: 40, p50, p75: p50 + 100, p95: p50 * 3 });

describe("N5b · Admin speed per screen", () => {
  it("shows the newest day per screen × app, with the day before for the trend", () => {
    const out = latestPerScreen([r("2026-11-22", "feed", "android", 900), r("2026-11-23", "feed", "android", 700), r("2026-11-23", "chat", "web", 400)]);
    const feed = out.find((x) => x.screen === "feed")!;
    expect(feed.day).toBe("2026-11-23");
    expect(feed.p50).toBe(700);
    expect(feed.prevP50).toBe(900);
    expect(out.find((x) => x.screen === "chat")!.prevP50).toBeNull();
  });

  it("app-start rows are listed after the normal ones", () => {
    const out = latestPerScreen([r("2026-11-23", "feed", "web", 3000, true), r("2026-11-23", "feed", "web", 500)]);
    expect(out.map((x) => x.cold)).toEqual([false, true]);
  });

  it("the red line is the alarm's line (one number in two places is checked)", () => {
    const sql = readFileSync(join(process.cwd(), "supabase/migrations/20261123_4900_n5_screen_speed.sql"), "utf8");
    expect(sql).toContain(`_p50_ms  constant integer := ${LIMIT_P50};`);
    expect(sql).toContain(`_p95_ms  constant integer := ${LIMIT_P95};`);
  });
});

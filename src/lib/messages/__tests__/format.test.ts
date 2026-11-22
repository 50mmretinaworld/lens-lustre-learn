import { describe, expect, it } from "vitest";
import { clockText, dayLabel, groupChat } from "../format";
import type { ThreadMessage } from "../api";

import { activeAgoText } from "../format";
describe("activeAgoText", () => {
  const now = new Date("2026-11-21T12:00:00Z");
  const ago = (ms: number) => new Date(now.getTime() - ms).toISOString();
  it("reads like Meta: minutes, hours, yesterday, days, then nothing", () => {
    expect(activeAgoText(ago(20_000), now)).toBe("Active just now");
    expect(activeAgoText(ago(12 * 60_000), now)).toBe("Active 12m ago");
    expect(activeAgoText(ago(3 * 3_600_000), now)).toBe("Active 3h ago");
    expect(activeAgoText(ago(30 * 3_600_000), now)).toBe("Active yesterday");
    expect(activeAgoText(ago(4 * 86_400_000), now)).toBe("Active 4d ago");
    expect(activeAgoText(ago(9 * 86_400_000), now)).toBeNull();
    expect(activeAgoText(null, now)).toBeNull();
    expect(activeAgoText("nonsense", now)).toBeNull();
  });
});

const m = (id: number, sender: string, iso: string): ThreadMessage => ({ id, senderId: sender, kind: "text", body: "x", createdAt: iso, status: "sent", tick: null, reply: null, photos: [] });

describe("messages display rules", () => {
  const now = new Date(2026, 10, 18, 12, 0);
  it("labels days", () => {
    expect(dayLabel(new Date(2026, 10, 18, 9, 0).toISOString(), now)).toBe("Today");
    expect(dayLabel(new Date(2026, 10, 17, 9, 0).toISOString(), now)).toBe("Yesterday");
    expect(dayLabel(new Date(2026, 10, 12, 9, 0).toISOString(), now)).toMatch(/12/);
  });

  it("groups a run and puts the tail on its last bubble", () => {
    const t = (min: number) => new Date(2026, 10, 18, 10, min).toISOString();
    const items = groupChat([m(1, "a", t(0)), m(2, "a", t(2)), m(3, "b", t(3)), m(4, "a", t(30))], now);
    const msgs = items.filter((i) => i.type === "msg") as Extract<(typeof items)[number], { type: "msg" }>[];
    expect(items[0].type).toBe("day");
    expect(msgs.map((i) => [i.first, i.last])).toEqual([[true, false], [false, true], [true, true], [true, true]]);
  });

  it("starts a new run and a new day chip across midnight", () => {
    const items = groupChat([m(1, "a", new Date(2026, 10, 17, 23, 59).toISOString()), m(2, "a", new Date(2026, 10, 18, 0, 1).toISOString())], now);
    expect(items.filter((i) => i.type === "day")).toHaveLength(2);
  });

  it("puts a centred time (Instagram) at a new day and after an hour's pause, never under every bubble", () => {
    const at = (h: number, min: number) => new Date(2026, 10, 18, h, min).toISOString();
    const items = groupChat([m(1, "a", at(9, 5)), m(2, "b", at(9, 20)), m(3, "a", at(16, 8))], now);
    const labels = items.filter((i) => i.type === "day").map((i) => (i as { label: string }).label);
    expect(labels).toEqual(["Today 9:05 AM", "4:08 PM"]);
  });

  it("writes the clock one way on every phone", () => {
    expect(clockText(new Date(2026, 10, 18, 4, 8).toISOString())).toBe("4:08 AM");
    expect(clockText(new Date(2026, 10, 18, 0, 5).toISOString())).toBe("12:05 AM");
    expect(clockText(new Date(2026, 10, 18, 12, 30).toISOString())).toBe("12:30 PM");
  });
});

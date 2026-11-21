import { describe, expect, it } from "vitest";
import { dayLabel, groupChat } from "../format";
import type { ThreadMessage } from "../api";

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
});

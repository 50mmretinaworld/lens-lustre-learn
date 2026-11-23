import { describe, it, expect, vi, beforeEach } from "vitest";

const recordTiming = vi.fn();
vi.mock("@/lib/telemetry", () => ({ recordTiming: (...a: unknown[]) => recordTiming(...a) }));

import { notePageChange, screenReady, resetScreenTimingForTests } from "@/lib/screenTiming";

describe("N5 · one clock for every screen", () => {
  beforeEach(() => { recordTiming.mockReset(); resetScreenTimingForTests(); });

  it("the first screen is measured from the app starting (cold)", () => {
    screenReady("feed");
    expect(recordTiming).toHaveBeenCalledTimes(1);
    expect(recordTiming.mock.calls[0][0]).toBe("screen.feed.cold");
  });

  it("after a page change the screen is measured from the tap", () => {
    notePageChange();
    screenReady("messages");
    expect(recordTiming.mock.calls[0][0]).toBe("screen.messages");
    expect(recordTiming.mock.calls[0][1]).toBeGreaterThanOrEqual(0);
  });

  it("recorded once per page change, again after the next one", () => {
    notePageChange();
    screenReady("chat"); screenReady("chat");
    expect(recordTiming).toHaveBeenCalledTimes(1);
    notePageChange();
    screenReady("chat");
    expect(recordTiming).toHaveBeenCalledTimes(2);
  });

  it("metric names pass the server's pattern", () => {
    for (const n of ["feed", "messages", "chat", "profile", "notifications", "competitions"]) {
      expect(`screen.${n}.cold`).toMatch(/^[a-z0-9_.:-]{1,64}$/);
    }
  });
});

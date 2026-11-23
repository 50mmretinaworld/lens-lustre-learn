import { describe, it, expect } from "vitest";
import { photoTier, feedSizesFor, MEDIUM_BELOW_MBPS } from "@/lib/net/photoTier";

const NORMAL = "(max-width: 430px) 360px, (max-width: 768px) 100vw, 600px";
const SMALL = "160px";

describe("N4 · photo size by measured speed", () => {
  it("slow link or Data Saver → small", () => {
    expect(photoTier(true, {})).toBe("small");
    expect(photoTier(false, { saveData: true })).toBe("small");
  });
  it("measured speed under the line → medium; above → large", () => {
    expect(photoTier(false, { downlink: MEDIUM_BELOW_MBPS - 0.5 })).toBe("medium");
    expect(photoTier(false, { downlink: MEDIUM_BELOW_MBPS + 5 })).toBe("large");
  });
  it("a browser that does not measure (iPhone / Safari) keeps today's rule: large unless seen slow", () => {
    expect(photoTier(false, undefined)).toBe("large");
    expect(photoTier(false, { downlink: 0 })).toBe("large");   // 0 = unknown in some WebViews
  });
  it("medium asks a 3x phone for no more than the 1080 copy", () => {
    expect(feedSizesFor("medium", NORMAL, SMALL, 3)).toBe("(max-width: 768px) 360px, 600px");
    expect(feedSizesFor("medium", NORMAL, SMALL, 2)).toBe("(max-width: 768px) 540px, 600px");
    expect(feedSizesFor("small", NORMAL, SMALL, 3)).toBe(SMALL);
    expect(feedSizesFor("large", NORMAL, SMALL, 3)).toBe(NORMAL);
  });
});

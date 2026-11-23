import { describe, expect, it } from "vitest";
import { compareVersions, isOldVersion, newestVersion, sortVersionsDesc } from "@/lib/versionCompare";

describe("compareVersions — numbers, not text", () => {
  it("1.2.10 is newer than 1.2.9 (text order would say the opposite)", () => {
    expect(compareVersions("1.2.10", "1.2.9")).toBe(1);
    expect(compareVersions("1.2.9", "1.2.10")).toBe(-1);
  });
  it("same version is 0; a missing part counts as 0", () => {
    expect(compareVersions("1.2.56", "1.2.56")).toBe(0);
    expect(compareVersions("1.2", "1.2.0")).toBe(0);
    expect(compareVersions("1.1", "1.0.9")).toBe(1);
  });
  it("major and minor outrank patch", () => {
    expect(compareVersions("2.0.0", "1.99.99")).toBe(1);
    expect(compareVersions("1.3.0", "1.2.99")).toBe(1);
  });
  it("a -beta / +build tail does not change the order", () => {
    expect(compareVersions("1.2.56-beta", "1.2.56")).toBe(0);
    expect(compareVersions("1.2.57+1160", "1.2.56")).toBe(1);
  });
  it("empty or null sorts lowest; a non-number part sorts below a number", () => {
    expect(compareVersions(null, "1.0")).toBe(-1);
    expect(compareVersions("1.0", "")).toBe(1);
    expect(compareVersions(undefined, null)).toBe(0);
    expect(compareVersions("1.x", "1.0")).toBe(-1);
  });
});

describe("newest / sort / old", () => {
  const seen = ["1.2.50", "1.2.9", "1.2.56", null, "1.2.10", "1.2.55"];
  it("newestVersion picks the highest number", () => {
    expect(newestVersion(seen)).toBe("1.2.56");
    expect(newestVersion([null, ""])).toBeNull();
  });
  it("sortVersionsDesc orders newest first", () => {
    expect(sortVersionsDesc(seen.filter(Boolean) as string[], (v) => v)).toEqual(["1.2.56", "1.2.55", "1.2.50", "1.2.10", "1.2.9"]);
  });
  it("isOldVersion is true only below the newest", () => {
    expect(isOldVersion("1.2.55", "1.2.56")).toBe(true);
    expect(isOldVersion("1.2.56", "1.2.56")).toBe(false);
    expect(isOldVersion(null, "1.2.56")).toBe(false);
    expect(isOldVersion("1.2.56", null)).toBe(false);
  });
});

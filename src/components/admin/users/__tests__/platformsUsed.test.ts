import { describe, it, expect } from "vitest";
import { platformsUsed } from "../memberUi";

// Owner 28 Nov: "Neil Basu uses App and Web both but showing only Web".
describe("Admin → Users lists every platform a member uses, not only the latest", () => {
  it("latest = website, but a phone reported an app version → both, website marked latest", () => {
    expect(platformsUsed({ last_platform: "web", app_version: "1.2.63", app_os: "android" })).toEqual([
      { kind: "web", label: "Website", latest: true },
      { kind: "app", label: "App 1.2.63 · Android", latest: false },
    ]);
  });
  it("latest = app without a reported version → App only", () => {
    expect(platformsUsed({ last_platform: "app", app_version: null })).toEqual([{ kind: "app", label: "App", latest: true }]);
  });
  it("website only → Website only", () => {
    expect(platformsUsed({ last_platform: "web", app_version: null })).toEqual([{ kind: "web", label: "Website", latest: true }]);
  });
  it("nothing recorded → nothing (the screen says Platform unknown)", () => {
    expect(platformsUsed({ last_platform: null })).toEqual([]);
  });
});

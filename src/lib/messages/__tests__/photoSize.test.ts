import { describe, expect, it } from "vitest";
import { fitWithin } from "../photoUpload";

describe("message photo sizing", () => {
  it("never upscales and keeps the aspect ratio", () => {
    expect(fitWithin(800, 600)).toEqual({ width: 800, height: 600 });
    expect(fitWithin(4000, 3000)).toEqual({ width: 1600, height: 1200 });
    expect(fitWithin(3000, 4000)).toEqual({ width: 1200, height: 1600 });
  });
  it("survives odd inputs", () => {
    expect(fitWithin(0, 0)).toEqual({ width: 1, height: 1 });
  });
});

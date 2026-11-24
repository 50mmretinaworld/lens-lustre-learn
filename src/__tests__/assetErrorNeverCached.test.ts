/**
 * Live incident 24 Nov 2026: right after a deploy the static pipeline answered some /assets/ files with an EMPTY 500
 * (no content-type). functions/assets/[[path]].ts stamped every non-HTML answer `immutable` for a year, so the error
 * was kept by Cloudflare for 9 files and members saw "Something went wrong". ONLY a delivered file (200) or a
 * confirmed copy (304) may be kept; anything else keeps its status and is never stored.
 */
// @vitest-environment node
import { describe, it, expect } from "vitest";
import { onRequest } from "../../functions/assets/[[path]]";

const run = (res: Response | (() => never)) =>
  onRequest({ request: new Request("https://www.50mmretina.com/assets/Index-x.js"), next: async () => (typeof res === "function" ? res() : res) });
const IMMUTABLE = "public, max-age=31536000, immutable";

describe("functions/assets: only a good answer may be kept for a year", () => {
  it("the incident: an empty 500 (no content-type) stays 500 and is never stored", async () => {
    const out = await run(new Response("", { status: 500, headers: { "cache-control": IMMUTABLE } }));
    expect(out.status).toBe(500);
    expect(out.headers.get("cache-control")).toMatch(/no-store/);
    expect(out.headers.get("cache-control")).not.toMatch(/immutable/);
  });
  it("502 / 503 / 404 from the pipeline: never stored", async () => {
    for (const status of [502, 503, 404]) {
      const out = await run(new Response("", { status }));
      expect(out.status, String(status)).toBe(status);
      expect(out.headers.get("cache-control"), String(status)).toMatch(/no-store/);
    }
  });
  it("the pipeline throwing: a never-stored 503", async () => {
    const out = await run(() => { throw new Error("pipeline down"); });
    expect(out.status).toBe(503);
    expect(out.headers.get("cache-control")).toMatch(/no-store/);
  });
  it("a delivered file (200 JS) and a confirmed copy (304) keep the 1-year cache", async () => {
    const ok = await run(new Response("export default 1", { status: 200, headers: { "content-type": "application/javascript" } }));
    expect(ok.status).toBe(200);
    expect(ok.headers.get("cache-control")).toBe(IMMUTABLE);
    const same = await run(new Response(null, { status: 304 }));
    expect(same.headers.get("cache-control")).toBe(IMMUTABLE);
  });
  it("the old bug stays fixed: HTML under /assets/ (a gone file) is a never-stored 404", async () => {
    const out = await run(new Response("<!doctype html>", { status: 200, headers: { "content-type": "text/html" } }));
    expect(out.status).toBe(404);
    expect(out.headers.get("cache-control")).toMatch(/no-store/);
  });
});

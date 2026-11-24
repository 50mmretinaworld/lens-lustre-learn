/**
 * Owner 24 Nov 2026: after a deploy Cloudflare stored empty 500s (carrying the 1-year "immutable" header) for 9
 * /assets/ files and the home page showed "Something went wrong" until the cache was purged. An error answer for a
 * file must say no-store; a good answer keeps its long cache; pages are untouched by this rule.
 */
// @vitest-environment node
import { describe, it, expect } from "vitest";
import { onRequest } from "../../functions/_middleware";

const ctx = (path: string, res: Response) => ({
  request: new Request("https://www.50mmretina.com" + path),
  env: { SEO_INJECT: "off" },
  next: async () => res,
});
const immutable = { "cache-control": "public, max-age=31536000, immutable", "content-type": "application/javascript" };

describe("an error for an asset is never stored (functions/_middleware.ts)", () => {
  it("a 500 for /assets/… goes out as no-store, status kept", async () => {
    const out = await onRequest(ctx("/assets/Index-DFYt_XBK.js", new Response("", { status: 500, headers: immutable })) as never);
    expect(out.status).toBe(500);
    expect(out.headers.get("cache-control")).toBe("no-store");
  });
  it("a 404 for /assets/… too", async () => {
    const out = await onRequest(ctx("/assets/gone.js", new Response("", { status: 404, headers: immutable })) as never);
    expect(out.headers.get("cache-control")).toBe("no-store");
  });
  it("a good asset keeps its 1-year cache", async () => {
    const out = await onRequest(ctx("/assets/Index-DFYt_XBK.js", new Response("export default 1", { status: 200, headers: immutable })) as never);
    expect(out.status).toBe(200);
    expect(out.headers.get("cache-control")).toBe("public, max-age=31536000, immutable");
  });
});

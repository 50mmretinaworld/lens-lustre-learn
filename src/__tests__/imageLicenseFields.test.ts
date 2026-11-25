/**
 * Google Search Console (25 Nov 2026): "Image Metadata — missing field license / acquireLicensePage" on post pages.
 * Every post photo's ImageObject must name both; the licence address must point at a section that exists.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const seo = readFileSync(join(process.cwd(), "supabase/functions/seo-route-metadata/index.ts"), "utf8");
const terms = readFileSync(join(process.cwd(), "src/pages/CommunityGuidelines.tsx"), "utf8");
const app = readFileSync(join(process.cwd(), "src/App.tsx"), "utf8");

describe("post photo structured data carries the licence fields", () => {
  const block = seo.slice(seo.indexOf('"@type": "ImageObject"'), seo.indexOf('"@type": "ImageObject"') + 900);

  it("ImageObject names license and acquireLicensePage", () => {
    expect(block).toMatch(/\blicense:\s*`\$\{SITE_URL\(\)\}\/terms-of-use#your-content`/);
    expect(block).toMatch(/\bacquireLicensePage:\s*authorUrl \?\? `\$\{SITE_URL\(\)\}\/help-support`/);
  });

  it("the licence address exists: /terms-of-use route + id=your-content section about ownership", () => {
    expect(app).toMatch(/path="\/terms-of-use"/);
    expect(app).toMatch(/path="\/help-support"/);
    const at = terms.indexOf('id="your-content"');
    expect(at).toBeGreaterThan(-1);
    expect(terms.slice(at, at + 600)).toMatch(/You keep ownership of the photographs/);
  });
});

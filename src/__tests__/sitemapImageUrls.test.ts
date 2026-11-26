/**
 * Search Console 26 Nov 2026: 89 "Invalid URL" in sitemap.xml — members without a photo carried the site's relative
 * fallback avatar as <image:loc>. The ONE entry builder lists a picture only when it has a full address, and
 * percent-encodes spaces (a featured-artist slug had them).
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import ts from "typescript";

const src = readFileSync(join(process.cwd(), "supabase/functions/sitemap/index.ts"), "utf8");
const pick = (name: string) => src.match(new RegExp(`function ${name}\\([\\s\\S]*?\\r?\\n}`))![0];
const js = ts.transpileModule(`${pick("escapeXml")}\n${pick("urlEntry")}`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
const urlEntry = new Function(`${js}; return urlEntry;`)() as (l: string, m?: string, c?: string, p?: string, i?: string) => string;

describe("sitemap picture and page addresses", () => {
  const page = "https://www.50mmretina.com/member.x";

  it("leaves out a relative fallback avatar, keeps the page", () => {
    const xml = urlEntry(page, undefined, undefined, undefined, "/avatars/fallback/m4.svg");
    expect(xml).toContain(`<loc>${page}</loc>`);
    expect(xml).not.toContain("image:loc");
  });

  it("keeps a real photograph, with & escaped", () => {
    const xml = urlEntry(page, undefined, undefined, undefined, "https://cdn.50mmretina.com/a.webp?x=1&y=2");
    expect(xml).toContain("<image:loc>https://cdn.50mmretina.com/a.webp?x=1&amp;y=2</image:loc>");
  });

  it("percent-encodes spaces and leaves existing encoding alone", () => {
    const xml = urlEntry("https://www.50mmretina.com/featured-artist/Mukti Bhavan Waiting");
    expect(xml).toContain("/featured-artist/Mukti%20Bhavan%20Waiting</loc>");
    expect(urlEntry("https://www.50mmretina.com/hashtag/%E0%A6%95")).toContain("/hashtag/%E0%A6%95</loc>");
  });
});

/**
 * B · Search Console 25 Nov 2026: /member.db9be324 was in sitemap.xml while its page said noindex
 * (x-seo-edge: injected:profile-moderated). The page head and the sitemap must read ONE rule for
 * "a banned or suspended member is not offered to search" — supabase/functions/_shared/moderated.ts.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const read = (p: string) => readFileSync(join(process.cwd(), p), "utf8");

describe("sitemap and page head share the moderated-member rule", () => {
  const shared = read("supabase/functions/_shared/moderated.ts");
  const head = read("supabase/functions/seo-route-metadata/index.ts");
  const sitemap = read("supabase/functions/sitemap/index.ts");

  it("the rule lives in one shared module (banned OR suspended)", () => {
    expect(shared).toMatch(/is_banned\.eq\.true,is_suspended\.eq\.true/);
    expect(shared).toMatch(/p\.is_banned \|\| p\.is_suspended/);
  });

  it("the page head reads it from the shared module, with no copy of its own", () => {
    expect(head).toMatch(/from "\.\.\/_shared\/moderated\.ts"/);
    expect(head).not.toMatch(/is_banned/);
  });

  it("the sitemap drops moderated members' profiles and posts", () => {
    expect(sitemap).toMatch(/import \{ moderatedSet \} from "\.\.\/_shared\/moderated\.ts"/);
    expect(sitemap).toMatch(/if \(!p\.custom_url \|\| moderated\.has\(p\.id\)\) continue;/);
    expect(sitemap).toMatch(/if \(moderated\.has\(p\.user_id\)\) continue;/);
    expect(sitemap).toMatch(/select\("id, custom_url, updated_at, avatar_url"\)/);
  });
});

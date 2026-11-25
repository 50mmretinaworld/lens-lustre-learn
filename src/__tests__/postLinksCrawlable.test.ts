/**
 * Search Console 25 Nov 2026 — 314 posts "Discovered, currently not indexed". Measured live after JS as Googlebot:
 * ZERO <a href> links to any post on home, profiles, hashtag pages, post pages. Google follows real links only;
 * every post was reachable through the sitemap alone. The two shared post surfaces must give a real link:
 *   - ProfilePostGrid tiles (profile grid, hashtag grid): <Link to={postPathOf(post)}>, never a button + navigate.
 *   - PostCard (feed, hashtag cards): the time is the post's permalink.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const read = (p: string) => readFileSync(join(process.cwd(), p), "utf8");

describe("posts are reachable by real links", () => {
  it("grid tiles are links to the post, not buttons that navigate", () => {
    const grid = read("src/components/profile/ProfilePostGrid.tsx");
    expect(grid.match(/<Link\s+to=\{postPathOf\(post\)\}/g)?.length).toBe(2); // GridTile + ShowcaseTile
    expect(grid).not.toMatch(/navigate\(postPathOf/);
    expect(grid).not.toMatch(/useNavigate/);
    // first tap still only reveals the counts (owner rule 2026-08-14): the link is held back once
    expect(grid).toMatch(/if \(!revealed\) \{\s*e\.preventDefault\(\);/);
  });

  it("the feed card's time is the post's permalink", () => {
    const card = read("src/components/post/PostCard.tsx");
    expect(card).toMatch(/<Link to=\{postPathOf\(post\)\}[^>]*>\{timeAgo\(post\.created_at\)\}<\/Link>/);
  });
});

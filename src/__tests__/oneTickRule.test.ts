import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

/**
 * ONE TICK RULE (Owner 28 Nov 2026): "if it changes in one place, all places must show it at one go."
 *
 * A person's tick (blue Verified / gold Elite Member) is drawn ONLY by the central chain:
 *   UserIdentityBlock / AutoBadge / UserBadgeInline → VerifiedTick → VerifiedTickMember
 * and, for places that speak as the official account without a member id (ads, ad page, broadcast preview),
 * OfficialAccountTick (which looks the account up and goes through the same chain).
 *
 * The sponsored-ad header and the ad page drew a fixed BLUE tick by hand, so the official account's change to
 * Elite never reached them. This test fails when any other file draws the tick glyph itself.
 */
const ROOT = join(process.cwd(), "src");

/** Files allowed to draw the tick glyph (VerifiedBadge) directly, and why. */
const GLYPH_ALLOWED: Record<string, string> = {
  "src/components/VerifiedBadge.tsx": "the glyph itself",
  "src/components/VerifiedTick.tsx": "the central chain (fallback while the popup piece loads)",
  "src/components/premium/VerifiedTickMember.tsx": "the central chain",
  "src/components/premium/VerifiedTickCard.tsx": "the tick's own popup, drawing the badge it explains",
  "src/components/feed/FeedPremiumMembers.tsx": "Premium Members section emblem, not a person's tick",
  "src/pages/PremiumMembers.tsx": "Premium Members page emblem, not a person's tick",
  "src/components/premium/ShareHonourButton.tsx": "the Share my honour button's icon, shown only to the honoured member",
};

/** Files allowed to use lucide's BadgeCheck icon (never beside a person's name). */
const BADGECHECK_ALLOWED: Record<string, string> = {
  "src/components/admin/AdminEmployee.tsx": "staff card 'Active' state",
  "src/pages/IDVerification.tsx": "staff ID status",
  "src/components/GroupMentionRow.tsx": "@all mention row icon",
};

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) return n === "__tests__" || n === "uiharness" ? [] : files(p);
    return /\.(tsx|ts)$/.test(p) && !/\.test\.tsx?$/.test(p) ? [p] : [];
  });
}

describe("one tick rule", () => {
  const all = files(ROOT).map((f) => ({ rel: relative(process.cwd(), f).replace(/\\/g, "/"), src: readFileSync(f, "utf8") }));

  it("only the central chain draws the tick glyph", () => {
    const bad = all
      .filter(({ rel, src }) => /from\s+["']@\/components\/VerifiedBadge["']/.test(src) && !GLYPH_ALLOWED[rel])
      .map(({ rel }) => rel);
    expect(bad, `draws the tick by hand — use AutoBadge / UserBadgeInline / OfficialAccountTick:\n${bad.join("\n")}`).toEqual([]);
  });

  it("no look-alike tick icon beside names", () => {
    const bad = all
      .filter(({ rel, src }) => /\bBadgeCheck\b/.test(src) && !BADGECHECK_ALLOWED[rel])
      .map(({ rel }) => rel);
    expect(bad, `uses lucide BadgeCheck as a tick:\n${bad.join("\n")}`).toEqual([]);
  });

  it("the ad header, the ad page and the broadcast preview use the official account's real badge", () => {
    for (const rel of ["src/components/ads/AdZone.tsx", "src/pages/AdDetail.tsx", "src/components/admin/messages/BroadcastComposer.tsx"]) {
      const src = all.find((f) => f.rel === rel)?.src ?? "";
      expect(src, rel).toContain("<OfficialAccountTick");
    }
  });

  it("the allow-lists name only files that exist", () => {
    for (const rel of [...Object.keys(GLYPH_ALLOWED), ...Object.keys(BADGECHECK_ALLOWED)]) {
      expect(all.some((f) => f.rel === rel), rel).toBe(true);
    }
  });
});

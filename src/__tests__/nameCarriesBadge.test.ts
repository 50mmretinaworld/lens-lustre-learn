import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

/**
 * ONE RULE: A MEMBER'S NAME CARRIES THE MEMBER'S BADGE, EVERYWHERE (Owner 28 Nov 2026: "Name with Badge centrally
 * and that will show everywhere where names are coming … deep check where rule broke").
 *
 * It broke wherever a screen printed `{…full_name…}` by hand instead of using the shared pieces: the journal's
 * "About the Author" box, the journal list, the followers sheet, story viewers, the tag picker, the group pickers,
 * the post caption, the winners box. Each now sits next to AutoBadge / UserBadgeInline (or uses UserIdentityBlock,
 * which draws the badge itself).
 *
 * This ratchet reads every .tsx file: a member name printed as JSX text must have a badge piece within the next
 * 3 lines, or be on the reviewed list below with the reason. A new screen that prints a bare name fails here.
 */
const ROOT = join(process.cwd(), "src");
const NAME = /\{\s*[\w?.!]*(full_name|fullName|author_name|authorName|sender_name|senderName|user_name|userName|member_name|memberName)\b[^}]*\}/;
const BADGE = /AutoBadge|UserBadgeInline|VerifiedTick|UserIdentityBlock/;

/** Reviewed: not a member's name row (own name in a form, a sentence, alt text …) or a known gap with its reason. */
const REVIEWED: Record<string, string> = {
  "src/components/comments/CommentThread.tsx": "floating story comments: rows carry no user id yet (gap, bug list item 16)",
  "src/components/messages/ChatPane.tsx": "typing dots: a name passed as a prop, not drawn as a name row",
  "src/components/premium/GuestFollowPrompt.tsx": "a sentence ('Follow <name>') for a signed-out visitor",
  "src/components/WallPosts.tsx": "the member's own composer ('You')",
  "src/pages/Dashboard.tsx": "own name heading, badge drawn on the next line",
  "src/pages/EditProfile.tsx": "form validation text",
  "src/pages/IDVerification.tsx": "staff ID card (staff, not a member name row)",
  "src/pages/PublicProfile.tsx": "displayName passed as props to menus",
  "src/pages/Signup.tsx": "own name while signing up",
  "src/components/premium/PremiumMemberCard.tsx": "badge drawn beside the name in the next element",
};

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) return n === "__tests__" || n === "uiharness" || n === "admin" ? [] : files(p);
    return p.endsWith(".tsx") ? [p] : [];
  });
}

describe("a member's name carries the badge (one rule)", () => {
  it("every hand-printed name has a badge piece beside it, or is on the reviewed list", () => {
    const bad: string[] = [];
    for (const f of files(ROOT)) {
      const rel = relative(process.cwd(), f).replace(/\\/g, "/");
      if (/\/Admin[A-Z]/.test(rel) || rel.endsWith("UserIdentityBlock.tsx")) continue;
      const lines = readFileSync(f, "utf8").split(/\r?\n/);
      lines.forEach((line, i) => {
        if (!NAME.test(line) || /alt=|aria-|title=|placeholder|\[0\]|toUpperCase|charAt/.test(line)) return;
        if (!/>\s*\{|^\s*\{/.test(line)) return; // JSX text only, not props
        const near = lines.slice(i, i + 4).join("\n");
        if (BADGE.test(near) || REVIEWED[rel]) return;
        bad.push(`${rel}:${i + 1}`);
      });
    }
    expect(bad, `name printed without the badge rule:\n${bad.join("\n")}`).toEqual([]);
  });

  it("the reviewed list only names files that still exist", () => {
    for (const rel of Object.keys(REVIEWED)) expect(() => statSync(join(process.cwd(), rel))).not.toThrow();
  });
});

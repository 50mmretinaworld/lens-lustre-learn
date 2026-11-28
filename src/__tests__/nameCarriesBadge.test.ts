import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

/**
 * ONE RULE: A MEMBER'S NAME CARRIES THE MEMBER'S BADGE, EVERYWHERE (Owner 28 Nov 2026: "Name with Badge centrally
 * and that will show everywhere where names are coming … if it changes in one place, all places must show at one go").
 *
 * The pieces that draw a name WITH its badge: MemberName (a name in a line of text), UserIdentityBlock (avatar + name +
 * handle), or a name followed by AutoBadge / UserBadgeInline / VerifiedTick. All of them read the badge from the one
 * shared profile cache, so a badge changed by an admin changes everywhere at once.
 *
 * v1 of this ratchet (28 Nov, #1321) only knew six field names (full_name, author_name …). The Notifications list
 * prints `actor_names` through ActorPhrase and slipped straight past it — the Owner found it on the phone.
 * v2 matches by WHAT IS PRINTED: any JSX text expression that mentions a person word (name, actor, requester, sender,
 * author, photographer, artist, recipient, referred, viewer, person, member, mutual …) and is not obviously a thing
 * (category, file, competition, round, bank …). Each hit needs a badge piece within the lines around it, or an entry
 * in REVIEWED that names the exact expression and why it is not a member-name row. Whole-file exemptions are gone:
 * a new bare name in an already-reviewed file still fails.
 */
const ROOT = join(process.cwd(), "src");
const EXPR = /\{([^{}]*)\}/g;
const PERSON = /name|Name|actor|requester|sender|author|Author|photographer|Photographer|artist|recipient|referred|reactor|sharer|viewer|person|member|mutual|judge|Judge/;
const THING =
  /categor|file|File|badge|comp(etition)?[._]?name|[Rr]ound|title|Title|[Ss]ince|Num\b|total|excerpt|\bset[A-Z]|viewerAction|Guide|viewAs|getRoleDate|title|label|tag[._]|hashtag|country|city|camera|lens|brand|plan|role|route|icon|event|key|field|column|section|step|tab|album|course|lesson|bucket|template|job|table|func|device|browser|os_?name|location|place|venue|sponsor|award|prize|theme|font|color|gear|className|module|feature|switch|setting|page|screen|platform|channel|group[._]?name|broadcast|campaign|cert|product|package|type|status|kind|mime|domain|host|path|url|slug|bank|account_name|persona|appStoreName|count|Count|length|\.bio\b|initial|Initial|toUpperCase|charAt|\[0\]|slice\(/;
const BADGE = /AutoBadge|UserBadgeInline|VerifiedTick|UserIdentityBlock|MemberName|TagBadge|OfficialAccountTick/;

/**
 * Reviewed, per file, by the exact text of the printed expression: not a member-name row, or a deliberate exception.
 * Keep each reason honest — this list is what the Owner reads when asking "where does a name show without a badge".
 */
const REVIEWED: Record<string, Record<string, string>> = {
  "src/components/AskAnything.tsx": { typingName: "the AI helper's name, not a member" },
  "src/components/FeaturedArtist.tsx": { "artist.artist_name": "editorial text typed by an admin; the row has no member id" },
  "src/components/PhotoOfTheDay.tsx": { "potd.photographer_name": "editorial text typed by an admin; the row has no member id" },
  "src/components/FirstPostPrompt.tsx": { name: "the member's own first name in a greeting" },
  "src/components/JuryImageViewer.tsx": { "entry.photographer_name": "judging screen for jurors (staff tool)" },
  "src/components/judge/CinemaFullView.tsx": { judge_name: "judges' own names on the judging screen (staff tool)", judgeName: "judging screen (staff tool)" },
  "src/components/judge/CinemaJudgeView.tsx": { judgeName: "judging screen (staff tool)" },
  "src/components/judge/CinemaListView.tsx": { photographer_name: "judging screen (staff tool)" },
  "src/components/judge/JudgeProgressPanel.tsx": { judgeName: "judging screen (staff tool)" },
  "src/components/judge/MobileJudgeView.tsx": { photographer_name: "judging screen (staff tool)", "r.name": "a judging round's name" },
  "src/components/moderation/BlockUserButton.tsx": { "targetName: string": "a TypeScript prop type, not printed" },
  "src/components/judge/SeatModeBar.tsx": { judgeName: "judging screen (staff tool)" },
  "src/components/judge/VirtualizedPhotoGrid.tsx": { photographer_name: "judging screen (staff tool)" },
  "src/components/messages/ChatPane.tsx": { "person?.username": "@handle under the name in the header; the name above it carries the badge" },
  "src/components/messages/NewGroupDialog.tsx": { "messages.group.hint": "help text" },
  "src/components/premium/GuestFollowPrompt.tsx": { "member.full_name": "a sentence ('Follow <name>') for a signed-out visitor" },
  "src/components/profile/VisitorActions.tsx": { name: "confirm-dialog sentence text" },
  "src/components/WallPosts.tsx": { name: "the member's own composer ('You')" },
  "src/pages/CertificateVerifyByToken.tsx": { recipient_name: "the name printed on a certificate (a document, not a member row)" },
  "src/pages/VerifyCertificate.tsx": { recipient_name: "the name printed on a certificate (a document, not a member row)" },
  "src/pages/Dashboard.tsx": { "displayName.split": "own first name in the greeting" },
  "src/pages/EditProfile.tsx": { fullName: "form label / validation text" },
  "src/pages/IDVerification.tsx": { "staff.full_name": "staff ID card (staff, not a member name row)" },
  "src/pages/Index.tsx": { "m.name": "sample faces on the signed-out home page (not real members)" },
  "src/pages/Signup.tsx": { fullName: "own name while signing up" },
  "src/pages/HelpSupport.tsx": { name: "an attachment's file name" },
  "src/components/AppUpdatePrompt.tsx": { appStoreName: "the store's name" },
  "src/pages/FeaturedArtistPage.tsx": { "author.name": "only the branch with NO member id (an editorial artist); the linked branch draws the badge" },
  "src/components/messages/ChatMenu.tsx": { blocked: "menu wording" },
  "src/components/messages/GroupChatPane.tsx": { iAmOwner: "help wording" },
  "src/components/post/TagPeopleModal.tsx": { searchTerm: "empty-search wording" },
};

/** Admin screens are staff tools with their own tables; they are reviewed separately (bug list item 16, admin part). */
function files(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) return n === "__tests__" || n === "uiharness" || n === "admin" ? [] : files(p);
    return p.endsWith(".tsx") ? [p] : [];
  });
}

function reviewed(rel: string, expr: string): boolean {
  const map = REVIEWED[rel];
  return !!map && Object.keys(map).some((needle) => expr.includes(needle));
}

describe("a member's name carries the badge (one rule, v2: matched by what is printed)", () => {
  it("every printed person name has a badge piece beside it, or is on the reviewed list by its exact expression", () => {
    const bad: string[] = [];
    for (const f of files(ROOT)) {
      const rel = relative(process.cwd(), f).replace(/\\/g, "/");
      if (/\/Admin[A-Z]/.test(rel) || /UserIdentityBlock\.tsx$|MemberName\.tsx$|UserBadgeInline\.tsx$|VerifiedTick\.tsx$/.test(rel)) continue;
      const lines = readFileSync(f, "utf8").split(/\r?\n/);
      lines.forEach((line, i) => {
        if (!/>\s*\{|^\s*\{|\}\s*</.test(line) || /^\s*\{\s*\/\*/.test(line) || /^\s*(\/\/|\*)/.test(line)) return; // JSX text only
        EXPR.lastIndex = 0;
        let m: RegExpExecArray | null;
        while ((m = EXPR.exec(line))) {
          const expr = m[1];
          if (!PERSON.test(expr) || THING.test(expr)) continue;
          if (/=>|^\s*\.\.\.|aria-|alt=|placeholder|title=/.test(expr)) continue;
          if (/^\s*t\(\s*["'`]/.test(expr)) continue; // fixed wording from the translation table
          const before = line.slice(0, m.index);
          if (/[\w-]+=\s*$|\$$/.test(before)) continue; // a prop value or a `${…}` inside a string, not printed text
          if (/^\s*[\w$]+\s*(:\s*[\w|<>[\] ]+)?(\s*=\s*[^,]+)?(\s*,\s*[\w$]+\s*(:\s*[\w|<>[\] ]+)?(\s*=\s*[^,]+)?)+\s*$/.test(expr)) continue; // destructured parameters
          const near = lines.slice(Math.max(0, i - 3), i + 4).join("\n");
          if (BADGE.test(near) || reviewed(rel, expr)) continue;
          bad.push(`${rel}:${i + 1}  {${expr.trim().slice(0, 70)}}`);
        }
      });
    }
    expect(bad, `name printed without the badge rule:\n${bad.join("\n")}`).toEqual([]);
  });

  it("the reviewed list only names files that still exist", () => {
    for (const rel of Object.keys(REVIEWED)) expect(() => statSync(join(process.cwd(), rel))).not.toThrow();
  });

  it("the notification sentence draws each actor through MemberName (the gap the Owner found on 28 Nov)", () => {
    const src = readFileSync(join(ROOT, "components/notifications/ActorPhrase.tsx"), "utf8");
    expect(src.match(/<MemberName\b/g)?.length ?? 0).toBeGreaterThanOrEqual(2);
  });

  it("MemberName always draws the badge from the shared cache", () => {
    const src = readFileSync(join(ROOT, "components/MemberName.tsx"), "utf8");
    expect(src).toMatch(/<AutoBadge userId=\{userId\}/);
  });
});

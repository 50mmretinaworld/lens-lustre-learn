/**
 * ONE RULE for member-written text (Owner 18 Nov 2026: a story comment showed
 * "@[Sri V R Narayanasw](83f6d083-…)"). A post / comment / story text is never
 * printed straight into the page: full text goes through <RichContentRenderer>,
 * a preview or label through memberTextPlain() (src/lib/memberText.ts).
 *
 * The ratchet below fails any .tsx that renders `{x.content}` / `{x.caption}`
 * as page text. An attribute (`value={x.content}`) is not page text and is not
 * matched. A file that genuinely shows text that is NOT member-written goes in
 * NOT_MEMBER_TEXT with its reason.
 */
import { describe, it, expect } from "vitest";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { cutText, memberTextPlain, memberTextResolved, parseMemberText, taggedMemberIds } from "@/lib/memberText";

const ROOT = resolve(__dirname, "../..");
const SRC = join(ROOT, "src");

const NOT_MEMBER_TEXT: Record<string, string> = {
  "src/components/chat/ChatMessage.tsx": "the help assistant's own replies and the member's question to it — no mention markup exists there",
};

function tsxFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) return name === "__tests__" || name === "uiharness" ? [] : tsxFiles(p);
    return p.endsWith(".tsx") ? [p] : [];
  });
}

/** `{post.content}` / `{c?.caption}` as page text; not `value={…}` (preceded by "="). */
const RAW = /(?<![=\w])\{\s*[A-Za-z_$][\w$]*(?:\??\.[\w$]+)*\??\.(content|caption)\s*\}/g;

describe("member text — one rule (no raw @[Name](id) on any screen)", () => {
  it("no screen prints a .content / .caption straight into the page", () => {
    const offenders: string[] = [];
    for (const file of tsxFiles(SRC)) {
      const rel = relative(ROOT, file).replace(/\\/g, "/");
      if (NOT_MEMBER_TEXT[rel]) continue;
      const lines = readFileSync(file, "utf8").split("\n");
      lines.forEach((line, i) => {
        for (const m of line.matchAll(RAW)) offenders.push(`${rel}:${i + 1} — ${m[0]}`);
      });
    }
    expect(
      offenders,
      "Member text printed raw shows a mention as @[Name](id). Use <RichContentRenderer content={…} /> for the full text " +
        "or memberTextPlain(…) (src/lib/memberText.ts) for a preview/label.",
    ).toEqual([]);
  });

  it("every exemption still names a real file", () => {
    for (const rel of Object.keys(NOT_MEMBER_TEXT)) expect(() => statSync(join(ROOT, rel))).not.toThrow();
  });
});

describe("ROOT RULE — a tag's name comes from the profile, one source (Owner 18 Nov)", () => {
  const ALLOWED_PARSER = new Set([
    "src/lib/memberText.ts",                 // THE parser
    "src/components/RichContentRenderer.tsx", // THE renderer (tags + hashtags in one pass)
    "src/lib/commentSearch.ts",               // matching only, never shown
    "src/lib/captionMentions.ts",             // WRITES the tag when a caption is posted
    "src/components/comments/CommentComposer.tsx", // WRITES the reply tag
    "src/components/MentionInput.tsx",        // the typing box (react-mentions markup)
  ]);
  const files = (dir: string): string[] =>
    readdirSync(dir).flatMap((n) => {
      const p = join(dir, n);
      if (statSync(p).isDirectory()) return n === "__tests__" || n === "uiharness" ? [] : files(p);
      return /\.(ts|tsx)$/.test(n) ? [p] : [];
    });

  it("no screen builds a tag's name from the text (memberTextPlain is matching-only)", () => {
    const off = tsxFiles(SRC).map((f) => relative(ROOT, f).replace(/\\/g, "/"))
      .filter((rel) => readFileSync(join(ROOT, rel), "utf8").includes("memberTextPlain("));
    expect(off, "Show member text with <MemberText> or <RichContentRenderer> — they read names from the profile.").toEqual([]);
  });

  it("there is no second tag parser anywhere in src/", () => {
    // the tag pattern as it is written in source: @\[([^\]  (or @\\[([^\\] inside a string)
    const PARSER = /@\\{1,2}\[\(\[\^\\{1,2}\]/;
    const off = files(SRC).map((f) => relative(ROOT, f).replace(/\\/g, "/"))
      .filter((rel) => !ALLOWED_PARSER.has(rel) && PARSER.test(readFileSync(join(ROOT, rel), "utf8")));
    expect(off, "Parse tags with parseMemberText() (src/lib/memberText.ts), not a new regex.").toEqual([]);
  });
});

describe("memberText — the pure parts", () => {
  const SRI = "83f6d083-e78e-4b74-8ac6-af3a9717e295";
  it("splits text into runs, member tags and group tags", () => {
    expect(parseMemberText(`Hi @[Sri V R](${SRI}) and @[@all](all)!`)).toEqual([
      { kind: "text", text: "Hi " },
      { kind: "member", id: SRI, storedName: "Sri V R" },
      { kind: "text", text: " and " },
      { kind: "group", group: "all" },
      { kind: "text", text: "!" },
    ]);
    expect(taggedMemberIds(`@[A](${SRI}) @[B](${SRI}) @[@followers](followers)`)).toEqual([SRI]);
  });
  it("the profile name wins over the name copied in the text; a missing profile falls back to the copy", () => {
    const names = new Map([[SRI, { full_name: "Sri V R Narayanaswamy", custom_url: "sri" }]]);
    expect(memberTextResolved(`@[Sri V R Narayanasw](${SRI}) 🙏`, names)).toBe("@Sri V R Narayanaswamy 🙏");
    expect(memberTextResolved(`@[Old Name](${SRI}) 🙏`, new Map([[SRI, { full_name: null, custom_url: null }]]))).toBe("@Old Name 🙏");
    expect(memberTextResolved("@[@all](all) its the time", names)).toBe("@all its the time");
  });
  it("matching-only plain text, and cutting", () => {
    expect(memberTextPlain(`@[Neil Basu](${SRI}) great`)).toBe("@Neil Basu great");
    expect(memberTextPlain(null)).toBe("");
    expect(cutText("@Neil Basu   great\n\nshot", 40)).toBe("@Neil Basu great shot");
    expect(cutText("abcdefghij", 6)).toBe("abcde…");
  });
});

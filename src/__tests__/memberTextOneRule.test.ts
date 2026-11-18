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
import { memberTextPlain, memberTextPreview } from "@/lib/memberText";

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

describe("memberTextPlain / memberTextPreview", () => {
  it("shows a mention as @Name and a group tag as @all / @followers", () => {
    expect(memberTextPlain("@[Sri V R Narayanasw](83f6d083-e78e-4b74-8ac6-af3a9717e295) 🙏")).toBe("@Sri V R Narayanasw 🙏");
    expect(memberTextPlain("@[@all](all) its the time")).toBe("@all its the time");
    expect(memberTextPlain("@[@followers](followers) hi")).toBe("@followers hi");
  });
  it("leaves other text, hashtags and line breaks alone; empty in, empty out", () => {
    expect(memberTextPlain("Nice #Birds\nsecond line")).toBe("Nice #Birds\nsecond line");
    expect(memberTextPlain(null)).toBe("");
    expect(memberTextPlain(undefined)).toBe("");
  });
  it("preview folds whitespace and cuts with …", () => {
    expect(memberTextPreview("@[Neil Basu](u1)   great\n\nshot", 40)).toBe("@Neil Basu great shot");
    expect(memberTextPreview("abcdefghij", 6)).toBe("abcde…");
  });
});

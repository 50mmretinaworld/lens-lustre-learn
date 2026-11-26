/**
 * RATCHET — nothing pinned to the top of the screen sits under the iPhone's status bar (Owner 26 Nov 2026).
 *
 * iPhone app screenshots: the logo on top of the time and battery, the top bar half under the camera island. THE rule
 * (src/index.css "THE PHONE'S OWN STATUS BAR", src/lib/native/safeArea.ts): on the iPhone app `--safe-top` is the
 * status bar's height; everywhere else it is 0px, so the website and Android are unchanged.
 *
 *  - `fixed inset-0` / `fixed inset-y-0` / `fixed top-0` overlays are handled by that one CSS rule — nothing to write.
 *  - A bar that STICKS to the top of the screen while the page scrolls must use `top-[var(--safe-top)]`, not `top-0`.
 *  - Something `fixed` a little below the top (a toast, a saved pill) must add the strip: `top-[calc(var(--safe-top)+…)]`.
 *
 * Allowed: a `sticky top-0` that sticks inside its own scroll box (a table header, a modal's progress line), listed
 * below with the reason — inside a box there is no status bar to clear.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = join(__dirname, "..");
const SKIP_DIRS = new Set(["__tests__", "uiharness", "test-utils"]);

/** file → substring of the allowed line, with the reason. */
const IN_A_BOX: Array<{ file: string; has: string; why: string }> = [
  { file: "components/OnboardingModal.tsx", has: "h-1 bg-muted sticky top-0", why: "progress line inside the modal's own scroll box" },
  { file: "components/Navbar.tsx", has: "sticky top-0 z-50 bg-background/80", why: "inside Layout's top-bar wrapper, which does the sticking (top-[var(--safe-top)])" },
  { file: "components/Layout.tsx", has: "The <nav> inside already carried `sticky top-0 z-50`", why: "a line inside a JSX comment, not code" },
  { file: "components/admin/AdminHealth.tsx", has: "<thead className=\"sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/AdminVoteRewardLedger.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/AwardsIntegrityAudit.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/EntryStatusDriftAudit.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/JudgingDriftAudit.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/JudgingForensicDriftAudit.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/JudgingInvariantsAudit.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/WalletReconciliationAudit.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
  { file: "components/admin/WalletReconciliationLogAudit.tsx", has: "sticky top-0", why: "table header inside a scroll box" },
];

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      if (!SKIP_DIRS.has(name)) walk(p, out);
    } else if (/\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name)) {
      out.push(p);
    }
  }
  return out;
}

const isComment = (line: string) => /^\s*(\/\/|\*|\/\*|\{\/\*)/.test(line);
// unprefixed (phone-size) classes only: `md:top-0` etc. do not apply on a phone
const STICKY_TOP0 = /(?<![\w:-])sticky(?![\w-])[^"'`]*(?<![\w:-])top-0(?![\w-])|(?<![\w:-])top-0(?![\w-])[^"'`]*(?<![\w:-])sticky(?![\w-])/;
const FIXED_TOP_N = /(?<![\w:-])fixed(?![\w-])[^"'`]*(?<![\w:-])top-(?:[1-9][\d.]*|px)(?![\w-])|(?<![\w:-])top-(?:[1-9][\d.]*|px)(?![\w-])[^"'`]*(?<![\w:-])fixed(?![\w-])/;

describe("the iPhone status bar (nothing pinned to the top sits under the time and battery)", () => {
  it("bars that stick to the top of the screen use top-[var(--safe-top)]; fixed things near the top add it", () => {
    const bad: string[] = [];
    for (const file of walk(SRC)) {
      const rel = relative(SRC, file).replace(/\\/g, "/");
      readFileSync(file, "utf8").split(/\r?\n/).forEach((line, i) => {
        if (isComment(line) || !line.includes("top-") || !(line.includes("sticky") || line.includes("fixed"))) return;
        if (!STICKY_TOP0.test(line) && !FIXED_TOP_N.test(line)) return;
        if (IN_A_BOX.some((a) => a.file === rel && line.includes(a.has))) return;
        bad.push(`${rel}:${i + 1}  ${line.trim().slice(0, 140)}`);
      });
    }
    expect(bad, `Use top-[var(--safe-top)] (or top-[calc(var(--safe-top)+…)]) — see src/index.css "THE PHONE'S OWN STATUS BAR":\n${bad.join("\n")}`).toEqual([]);
  }, 30_000);

  it("the one rule exists: --safe-top is 0px except on the iPhone app, which reads the phone's strip", () => {
    const css = readFileSync(join(SRC, "index.css"), "utf8");
    expect(css).toMatch(/:root\s*\{[^}]*--safe-top:\s*0px/);
    expect(css).toMatch(/html\.app-ios\s*\{[^}]*--safe-top:\s*env\(safe-area-inset-top, 0px\)/);
    expect(css).toMatch(/html\.app-ios body\s*\{[^}]*padding-top:\s*var\(--safe-top\)/);
    expect(css).toMatch(/html\.app-ios \.fixed\.inset-0,\s*html\.app-ios \.fixed\.inset-y-0,\s*html\.app-ios \.fixed\.top-0\s*\{[^}]*top:\s*var\(--safe-top\)/);
    // every full-height rule gives the strip its share
    // (staging: no .h-app / TopBanners yet — main has them and checks .h-app too)
    expect(css).toMatch(/\.h-screen-safe\s*\{[^}]*100dvh - var\(--safe-top\)/);
    expect(css).toMatch(/\.app-frame \.min-h-screen\s*\{[^}]*100dvh - var\(--banner-h, 0px\) - var\(--safe-top\)/);
  });
});

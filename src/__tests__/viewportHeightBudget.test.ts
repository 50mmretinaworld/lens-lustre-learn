/**
 * RATCHET — every IN-PAGE full-height container leaves room for the status bars (Owner 23 Nov 2026).
 *
 * The slow-connection bar (TopBanners) sits in the page above the screen. A container sized to exactly the screen
 * height (h-screen, h-[100dvh], h-[calc(100vh-…)]) is then pushed down by the bar and its bottom — the chat's
 * message box, a login button — goes off screen. THE rule: use `.h-app` or subtract `var(--banner-h)`.
 *
 * Allowed without it: `fixed` overlays (they sit above the page, the bars do not push them), `min-h-*` / `max-h-*`
 * (the page can still scroll), and the few lines listed in ALLOWED with their reason.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = join(__dirname, "..");
const SKIP_DIRS = new Set(["__tests__", "uiharness", "test-utils"]);

/** file → substring of the one allowed line, with the reason. */
const ALLOWED: Array<{ file: string; has: string; why: string }> = [
  { file: "index.css", has: "height: 100vh;", why: "the .h-screen-safe / .h-app definitions themselves" },
  { file: "index.css", has: "height: 100dvh;", why: "the .h-screen-safe definition (fixed overlays)" },
  { file: "components/admin/MobileAdminNav.tsx", has: "h-[calc(100vh-120px)]", why: "inside the admin menu Sheet, which is a fixed overlay" },
  { file: "components/comments/CommentsOverlay.tsx", has: "NOT h-screen", why: "a line inside a JSX comment, not code" },
];

// exact heights only: h-screen (not min-h-screen / h-screen-safe), h-dvh, h-[…100dvh|100vh…], CSS height: 100dvh|100vh
const EXACT = /(?<![\w-])h-screen(?![\w-])|(?<![\w-])h-dvh(?![\w-])|(?<![\w-])h-\[[^\]]*100d?vh[^\]]*\]|(?<![\w-])height:\s*100d?vh/;

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      if (!SKIP_DIRS.has(name)) walk(p, out);
    } else if (/\.(tsx?|css)$/.test(name) && !/\.test\.tsx?$/.test(name)) {
      out.push(p);
    }
  }
  return out;
}

const isComment = (line: string) => /^\s*(\/\/|\*|\/\*|\{\/\*)/.test(line);

describe("viewport height budget (status bars never push a screen's bottom off)", () => {
  it("every in-page full-height container subtracts var(--banner-h) or uses .h-app", () => {
    const bad: string[] = [];
    for (const file of walk(SRC)) {
      const rel = relative(SRC, file).replace(/\\/g, "/");
      readFileSync(file, "utf8").split(/\r?\n/).forEach((line, i) => {
        if (isComment(line) || !EXACT.test(line)) return;
        if (line.includes("var(--banner-h)")) return;
        if (/(?<![\w-])fixed(?![\w-])/.test(line)) return;
        if (ALLOWED.some((a) => a.file === rel && line.includes(a.has))) return;
        bad.push(`${rel}:${i + 1}  ${line.trim().slice(0, 140)}`);
      });
    }
    expect(bad, `Use .h-app or calc(100dvh - var(--banner-h)) — see src/components/TopBanners.tsx:\n${bad.join("\n")}`).toEqual([]);
  });

  it("the bars live in ONE place that publishes --banner-h", () => {
    const bars = readFileSync(join(SRC, "components/TopBanners.tsx"), "utf8");
    expect(bars).toMatch(/--banner-h/);
    expect(bars).toMatch(/<NetworkBanner \/>/);
    const css = readFileSync(join(SRC, "index.css"), "utf8");
    expect(css).toMatch(/\.h-app\s*\{[^}]*var\(--banner-h\)/);
  });
});

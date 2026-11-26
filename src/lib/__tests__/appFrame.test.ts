/**
 * Owner 24 Nov 2026 (iPhone): "all screens have a scroll bar … screen-wise tight", "footer buttons must always be
 * in footer". Measured in WebKit at iPhone size: every min-h-screen page was 96 px taller than the phone. These
 * checks keep the ONE frame rule in place (src/lib/appFrame.ts + index.css + Layout).
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { inFlowHeight } from "@/lib/appFrame";
import { isBottomBarHidden } from "@/lib/appBar";

const css = readFileSync(join(process.cwd(), "src/index.css"), "utf8");
const layout = readFileSync(join(process.cwd(), "src/components/Layout.tsx"), "utf8");

describe("the app frame: a page's whole screen = the screen minus the frame", () => {
  it("min-h-screen inside the frame subtracts the status bars, the top bar and the bottom-bar room", () => {
    const rule = css.match(/\.app-frame \.min-h-screen\s*\{([^}]*)\}/)?.[1] ?? "";
    for (const v of ["--banner-h", "--frame-top", "--frame-bottom", "100dvh"]) expect(rule).toContain(v);
  });

  it("the bottom-bar room is 3rem on phones and 0 on a phone chat and from lg up", () => {
    expect(css).toMatch(/\.app-frame\s*\{\s*--frame-bottom:\s*3rem;/);
    expect(css).toMatch(/\.app-frame--no-bar\s*\{\s*--frame-bottom:\s*0px;/);
    expect(css).toMatch(/@media \(min-width: 1024px\)\s*\{\s*\.app-frame,\s*html\.app-ios \.app-frame\s*\{\s*--frame-bottom:\s*0px;/);
  });

  it("Layout wraps every page in the frame and publishes the top bar's height", () => {
    expect(layout).toContain('"app-frame pb-12 lg:pb-0"');
    expect(layout).toContain('"app-frame app-frame--no-bar lg:pb-0"');
    expect(layout).toMatch(/ref=\{frameTopRef\}/);
  });

  it("the frame keeps bottom-bar room ONLY where the bar shows — the ONE rule both read (measured live: Login 900 px on 852)", () => {
    expect(layout).toMatch(/isBottomBarHidden\(pathname\) \? "app-frame app-frame--no-bar lg:pb-0"/);
    const nav = readFileSync(join(process.cwd(), "src/components/MobileBottomNav.tsx"), "utf8");
    expect(nav).toMatch(/if \(isBottomBarHidden\(pathname\)\) return null;/);
    expect(nav).not.toMatch(/const hideRoutes =/);
  });

  it("isBottomBarHidden: sign-in pages, admin and a phone chat have no bar; everything else has it", () => {
    for (const p of ["/login", "/signup", "/forgot-password", "/reset-password", "/admin/users", "/messages/with/abc"]) {
      expect(isBottomBarHidden(p)).toBe(true);
    }
    for (const p of ["/", "/feed", "/messages", "/messages/requests", "/profile", "/competitions"]) {
      expect(isBottomBarHidden(p)).toBe(false);
    }
  });

  it("inside the installed app only, the page does not bounce (the fixed bottom bar is not dragged)", () => {
    expect(css).toMatch(/html\.app-zoom-locked,\s*html\.app-zoom-locked body\s*\{\s*overscroll-behavior:\s*none;/);
  });

  it("a top bar that floats over the page (or is missing) takes no room", () => {
    expect(inFlowHeight(null)).toBe(0);
    const el = document.createElement("div");
    el.style.position = "absolute";
    document.body.appendChild(el);
    expect(inFlowHeight(el)).toBe(0);
    el.remove();
  });
});

#!/usr/bin/env node
/**
 * MESSAGES REDESIGN — `node tools/uishot/messages-design-shots.mjs <out-dir> [suffix]`
 *
 * Photographs the REAL messages screens next to the app's own pages (feed, notifications, profile) so the
 * messenger can be checked against the app's design pattern. Phone 390 × 844 (the app) and desktop 1280.
 * Never fails on a scene: a scene that does not render is listed, the others are still saved.
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
const SUFFIX = process.argv[3] ?? "REAL";
if (!OUT) throw new Error("usage: messages-design-shots.mjs <out-dir> [suffix]");
mkdirSync(OUT, { recursive: true });

const PORT = Number(process.env.SHOT_PORT ?? 5298);
const BASE = `http://127.0.0.1:${PORT}`;
const viteBin = join(dirname(createRequire(import.meta.url).resolve("vite/package.json")), "bin", "vite.js");
const server = spawn(process.execPath, [viteBin, "--host", "127.0.0.1", "--port", String(PORT), "--strictPort"], {
  stdio: "ignore",
  env: {
    ...process.env,
    VITE_SUPABASE_URL: "https://testprojectref0000x.supabase.co",
    VITE_SUPABASE_PUBLISHABLE_KEY: "test-publishable-key-not-real",
    VITE_SUPABASE_PROJECT_ID: "testprojectref0000x",
  },
});

async function waitForServer() {
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(`${BASE}/uiharness.html`)).ok) return; } catch { /* not yet */ }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error("vite did not start");
}

const DESKTOP = { width: 1280, height: 900 };
const PHONE = { width: 390, height: 844 };
const DARK = (process.env.SHOT_THEME ?? "dark") === "dark";

/** [file, scene(+query), viewport, steps(page)] */
const SHOTS = [
  ["inbox-phone", "screen-messages", PHONE, null],
  ["requests-phone", "screen-messages", PHONE, async (p) => { await p.getByRole("tab", { name: /Requests/i }).first().click(); await p.waitForTimeout(800); }],
  ["chat-phone", "screen-message-thread", PHONE, null],
  ["request-chat-phone", "screen-message-request", PHONE, null],
  ["chat-menu-phone", "screen-message-thread", PHONE, async (p) => { const b = p.getByTestId("chat-menu"); if (await b.count()) { await b.first().click(); await p.waitForTimeout(600); } }],
  ["inbox-desktop", "screen-messages", DESKTOP, null],
  ["chat-desktop", "screen-message-thread", DESKTOP, null],
  // the app's own pages, for the pattern
  ["ref-feed-phone", "screen-feed", PHONE, null],
  ["ref-notifications-phone", "screen-notifications", PHONE, null],
  ["ref-friends-phone", "screen-friends", PHONE, null],
  ["ref-post-detail-phone", "screen-post-detail", PHONE, null],
  ["ref-notification-settings-phone", "screen-notification-settings", PHONE, null],
];

const ONLY = process.env.SHOT_ONLY ? new Set(process.env.SHOT_ONLY.split(",")) : null;
let browser;
try {
  await waitForServer();
  browser = await chromium.launch();
  for (const [name, scene, viewport, steps] of SHOTS) {
    if (ONLY && !ONLY.has(name)) continue;
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, reducedMotion: "reduce", isMobile: viewport.width < 600, hasTouch: viewport.width < 600, colorScheme: DARK ? "dark" : "light" });
    const page = await context.newPage();
    try {
      if (DARK) await page.addInitScript(() => { try { localStorage.setItem("theme", "dark"); } catch { /* */ } });
      await page.goto(`${BASE}/uiharness.html?scene=${scene}&strict=0`, { waitUntil: "load", timeout: 180000 });
      await page.waitForTimeout(4500);
      if (steps) await steps(page);
      await page.screenshot({ path: join(OUT, `messages-${name}-${SUFFIX}.png`), fullPage: false });
      console.log(`${name}: saved`);
    } catch (e) {
      console.log(`${name}: NOT SAVED — ${String(e).slice(0, 160)}`);
    }
    await context.close();
  }
} catch (e) {
  console.error(e);
} finally {
  if (browser) await browser.close();
  server.kill();
}

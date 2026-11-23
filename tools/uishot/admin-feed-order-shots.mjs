#!/usr/bin/env node
/**
 * ADMIN → FEED → FEED ORDER — `node tools/uishot/admin-feed-order-shots.mjs <out-dir>`
 *
 * Photographs the REAL AdminPanel at /admin/feed_order (scene
 * screen-admin-feed-order, 20261123_4600) in Chromium at desktop 1280 and
 * phone 390: the switch as created (Off = Fair mix) and with "Selected
 * members" + two members on the list. Fails if any request had no fixture.
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
if (!OUT) throw new Error("usage: admin-feed-order-shots.mjs <out-dir>");
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
/** [file, mode, viewport, fullPage] */
const SHOTS = [
  ["desktop-off", "off", DESKTOP, false],
  ["desktop-selected", "selected", DESKTOP, false],
  ["desktop-all", "everyone", DESKTOP, false],
  ["phone-off", "off", PHONE, true],
  ["phone-selected", "selected", PHONE, true],
];

let failed = false;
try {
  await waitForServer();
  const browser = await chromium.launch();
  for (const [name, mode, viewport, fullPage] of SHOTS) {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, reducedMotion: "reduce", isMobile: viewport.width < 600, hasTouch: viewport.width < 600 });
    const page = await context.newPage();
    const missing = [];
    page.on("console", (m) => { if (/NO FIXTURE/.test(m.text())) missing.push(m.text().slice(0, 160)); });
    await page.goto(`${BASE}/uiharness.html?scene=screen-admin-feed-order&strict=0&mode=${mode}`, { waitUntil: "load", timeout: 180000 });
    if (viewport.width < 768) {
      await page.getByRole("button", { name: /^Feed Order$/ }).first().click({ timeout: 60000 });
    }
    await page.waitForSelector("text=Feed order: Newest first", { timeout: 60000 });
    await page.waitForTimeout(1200);
    // The admin menu scrolls its active entry into view, which scrolls the window: start at the top.
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(400);
    await page.screenshot({ path: join(OUT, `admin-feed-order-${name}-REAL.png`), fullPage });
    const uniq = [...new Set(missing)];
    console.log(`${name}: saved${uniq.length ? ` — MISSING FIXTURES: ${uniq.join(" | ")}` : ""}`);
    if (uniq.length) failed = true;
    await context.close();
  }
  await browser.close();
} catch (e) {
  console.error(e);
  failed = true;
} finally {
  server.kill();
}
process.exit(failed ? 1 : 0);

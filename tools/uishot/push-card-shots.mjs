#!/usr/bin/env node
/**
 * PN4 item 9 — "TURN ON NOTIFICATIONS" CARD, NOW vs NEW — `node tools/uishot/push-card-shots.mjs <out-dir>`
 *
 * Photographs the REAL /notifications and /settings/notifications in app mode
 * (`?native=1`) at phone width 390, Chromium. NEW adds `&pushoff=1`: the phone
 * stub answers "notifications are off", so PushPermissionCard shows.
 * Fails if any request had no fixture (the picture would be missing data).
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
if (!OUT) throw new Error("usage: push-card-shots.mjs <out-dir>");
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

const PHONE = { width: 390, height: 844 };
/** [file, scene, pushoff] */
const SHOTS = [
  ["NOW-notifications", "screen-notifications", false],
  ["NEW-notifications", "screen-notifications", true],
  ["NOW-settings", "screen-notification-settings", false],
  ["NEW-settings", "screen-notification-settings", true],
];

let failed = false;
try {
  await waitForServer();
  const browser = await chromium.launch();
  for (const [name, scene, off] of SHOTS) {
    const context = await browser.newContext({ viewport: PHONE, deviceScaleFactor: 2, reducedMotion: "reduce", isMobile: true, hasTouch: true });
    const page = await context.newPage();
    const missing = [];
    page.on("console", (m) => { if (/NO FIXTURE/.test(m.text())) missing.push(m.text().slice(0, 160)); });
    await page.goto(`${BASE}/uiharness.html?scene=${scene}&strict=0&native=1${off ? "&pushoff=1" : ""}`, { waitUntil: "load", timeout: 180000 });
    await page.waitForSelector("h1", { timeout: 60000 });
    if (off) await page.waitForSelector("[data-testid='push-permission-card']", { timeout: 30000 });
    await page.waitForTimeout(1500);
    const card = await page.locator("[data-testid='push-permission-card']").count();
    if (off !== (card === 1)) { console.error(`${name}: card shown=${card} but expected ${off}`); failed = true; }
    await page.screenshot({ path: join(OUT, `push-card-${name}-REAL.png`), fullPage: false });
    const uniq = [...new Set(missing)];
    console.log(`${name}: saved (card ${card ? "shown" : "absent"})${uniq.length ? ` — MISSING FIXTURES: ${uniq.join(" | ")}` : ""}`);
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

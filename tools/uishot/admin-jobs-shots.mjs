#!/usr/bin/env node
/**
 * ADMIN → JOB ENGINE (J5a) — `node tools/uishot/admin-jobs-shots.mjs <out-dir>`
 *
 * Photographs the REAL AdminPanel at /admin/jobs (scene screen-admin-jobs,
 * sample shaped like production 18 Nov 2026 + one failure) in Chromium at
 * desktop 1280 and phone 390. Fails if any request had no fixture.
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
if (!OUT) throw new Error("usage: admin-jobs-shots.mjs <out-dir>");
mkdirSync(OUT, { recursive: true });

const PORT = Number(process.env.SHOT_PORT ?? 5299);
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

/** [file, viewport, steps(page), fullPage] */
const SHOTS = [
  ["desktop", DESKTOP, null, true],
  ["desktop-top", DESKTOP, null, false],
  ["desktop-failed-filter", DESKTOP, async (p) => { await p.getByRole("button", { name: "Failed", exact: true }).click(); await p.waitForTimeout(600); }, false],
  ["desktop-push-selected", DESKTOP, async (p) => { await p.getByTestId("job-kind-card").last().click(); await p.waitForTimeout(600); }, true],
  ["phone", PHONE, null, true],
];

let failed = false;
try {
  await waitForServer();
  const browser = await chromium.launch();
  for (const [name, viewport, steps, fullPage] of SHOTS) {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, reducedMotion: "reduce", isMobile: viewport.width < 600, hasTouch: viewport.width < 600 });
    const page = await context.newPage();
    const missing = [];
    page.on("console", (m) => { if (/NO FIXTURE/.test(m.text())) missing.push(m.text().slice(0, 160)); });
    await page.goto(`${BASE}/uiharness.html?scene=screen-admin-jobs&strict=0`, { waitUntil: "load", timeout: 180000 });
    // Phones open the admin menu first (MobileAdminNav); tap "Job Engine" as an admin would.
    if (viewport.width < 768) {
      await page.getByRole("button", { name: /^Job Engine$/ }).first().click({ timeout: 60000 });
    }
    await page.waitForSelector("[data-testid='job-kind-card']", { timeout: 60000 });
    await page.waitForTimeout(1200);
    if (steps) await steps(page);
    await page.screenshot({ path: join(OUT, `admin-jobs-${name}-REAL.png`), fullPage });
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

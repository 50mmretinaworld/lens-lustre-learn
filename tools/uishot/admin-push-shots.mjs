#!/usr/bin/env node
/**
 * ADMIN → PUSH NOTIFICATION, NOW vs NEW — `node tools/uishot/admin-push-shots.mjs <out-dir> [now|new|all]`
 *
 * Photographs the REAL AdminPanel at /admin/push_notification (scene
 * screen-admin-push, adminPushSample.ts) in Chromium at desktop 1280 and
 * phone 390. `?pushui=old` shows the current one-box page.
 * Fails if any request had no fixture (the picture would be missing data).
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
const WHICH = process.argv[3] ?? "all";
if (!OUT) throw new Error("usage: admin-push-shots.mjs <out-dir> [now|new|all]");
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

/** Fill the composer from the "Competition closing" template (countdown, slides, buttons). */
const useTemplate = async (p) => {
  await p.getByTestId("push-tab-templates").click();
  await p.getByRole("button", { name: /^Use$/ }).first().click();
  await p.waitForTimeout(700);
};

/** [file, ui, viewport, steps(page), fullPage] */
const SHOTS = [
  ["NOW-desktop", "old", DESKTOP, null, false],
  ["NOW-phone", "old", PHONE, null, false],
  ["NEW-desktop", "new", DESKTOP, useTemplate, false],
  ["NEW-desktop-full", "new", DESKTOP, useTemplate, true],
  ["NEW-desktop-audience-role", "new", DESKTOP, async (p) => { await useTemplate(p); await p.getByTestId("push-audience-role").click(); await p.waitForTimeout(600); await p.getByTestId("push-audience").scrollIntoViewIfNeeded(); }, false],
  ["NEW-desktop-confirm", "new", DESKTOP, async (p) => { await useTemplate(p); await p.getByTestId("push-send").click(); await p.waitForTimeout(500); }, false],
  ["NEW-desktop-history", "new", DESKTOP, async (p) => { await p.getByTestId("push-tab-history").click(); await p.waitForTimeout(500); await p.getByTestId("push-history-row").first().click(); await p.waitForTimeout(400); }, false],
  ["NEW-desktop-scheduled", "new", DESKTOP, async (p) => { await p.getByTestId("push-tab-scheduled").click(); await p.waitForTimeout(500); }, false],
  ["NEW-phone", "new", PHONE, useTemplate, true],
  ["NEW-phone-history", "new", PHONE, async (p) => { await p.getByTestId("push-tab-history").click(); await p.waitForTimeout(500); await p.getByTestId("push-history-row").first().click(); await p.waitForTimeout(400); }, false],
].filter(([name]) => WHICH === "all" || name.toLowerCase().startsWith(WHICH));

let failed = false;
try {
  await waitForServer();
  const browser = await chromium.launch();
  for (const [name, ui, viewport, steps, fullPage] of SHOTS) {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, reducedMotion: "reduce", isMobile: viewport.width < 600, hasTouch: viewport.width < 600 });
    const page = await context.newPage();
    const missing = [];
    page.on("console", (m) => { if (/NO FIXTURE/.test(m.text())) missing.push(m.text().slice(0, 160)); });
    const q = ui === "old" ? "&pushui=old" : "";
    await page.goto(`${BASE}/uiharness.html?scene=screen-admin-push&strict=0${q}`, { waitUntil: "load", timeout: 180000 });
    // Phones open the admin menu first (MobileAdminNav); tap the entry as an admin would.
    if (viewport.width < 768) {
      await page.getByRole("button", { name: /^Push Notification$/ }).first().click({ timeout: 60000 });
    }
    await page.waitForSelector(ui === "old" ? "text=Send a notification to everyone" : "[data-testid='push-centre']", { timeout: 60000 });
    await page.waitForTimeout(1200);
    if (steps) await steps(page);
    await page.screenshot({ path: join(OUT, `admin-push-${name}-REAL.png`), fullPage });
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

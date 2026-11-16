#!/usr/bin/env node
/**
 * ADMIN → USERS, NOW vs NEW — `node tools/uishot/admin-users-shots.mjs <out-dir> [now|new|all]`
 *
 * Photographs the REAL AdminPanel at /admin/users (scene screen-admin-users,
 * 1,284 synthetic members) in Chromium at desktop 1280 and phone 390.
 * `?usersui=old` forces the current list; the default is what the code ships.
 * Fails if any request had no fixture (the picture would be missing data).
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
const WHICH = process.argv[3] ?? "all";
if (!OUT) throw new Error("usage: admin-users-shots.mjs <out-dir> [now|new|all]");
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

/** [file, ui, viewport, steps(page), fullPage] */
const SHOTS = [
  ["NOW-desktop", "old", DESKTOP, null, false],
  ["NOW-phone", "old", PHONE, null, false],
  ["NEW-desktop", "new", DESKTOP, null, false],
  ["NEW-desktop-suspended", "new", DESKTOP, async (p) => { await p.getByTestId("status-tab-suspended").click(); await p.waitForTimeout(600); }, false],
  ["NEW-desktop-row-menu", "new", DESKTOP, async (p) => { await p.getByTestId("member-row-menu").nth(2).click(); await p.waitForTimeout(400); }, false],
  ["NEW-desktop-bulk", "new", DESKTOP, async (p) => {
    const boxes = p.getByTestId("member-row-select");
    for (const i of [0, 1, 3]) await boxes.nth(i).click();
    await p.waitForTimeout(300);
  }, false],
  ["NEW-desktop-drawer", "new", DESKTOP, async (p) => { await p.getByTestId("member-open").nth(6).click(); await p.waitForTimeout(800); }, false],
  ["NEW-phone", "new", PHONE, null, false],
  ["NEW-phone-filters", "new", PHONE, async (p) => { await p.getByTestId("members-filters-open").click(); await p.waitForTimeout(600); }, false],
  ["NEW-phone-drawer", "new", PHONE, async (p) => { await p.getByTestId("member-open").nth(6).click(); await p.waitForTimeout(800); }, false],
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
    const q = ui === "old" ? "&usersui=old" : "";
    await page.goto(`${BASE}/uiharness.html?scene=screen-admin-users&strict=0${q}`, { waitUntil: "load", timeout: 180000 });
    await page.waitForSelector("[data-member-id], [data-testid='member-row']", { timeout: 60000, state: "attached" });
    // Phones open the admin menu first (MobileAdminNav); tap "Users" as a member would.
    if (viewport.width < 768) await page.getByRole("button", { name: /^Users$/ }).first().click();
    await page.waitForTimeout(1200);
    if (steps) await steps(page);
    await page.screenshot({ path: join(OUT, `admin-users-${name}-REAL.png`), fullPage });
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

#!/usr/bin/env node
/**
 * ADMIN → MESSAGES (M8b) — `node tools/uishot/admin-messages-shots.mjs <out-dir>`
 *
 * Photographs the REAL AdminPanel at /admin/messages (scene screen-admin-messages,
 * sample = launch state: "Only people on my list", the Owner alone, one held message)
 * in Chromium at desktop 1280 and phone 390. Fails if any request had no fixture.
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
if (!OUT) throw new Error("usage: admin-messages-shots.mjs <out-dir>");
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

const reason = async (p, text) => {
  await p.getByTestId("messages-reason").fill(text);
  await p.waitForTimeout(200);
};
/** pick the first search result of a member picker */
const pick = async (p, label, q) => {
  await p.getByLabel(label, { exact: false }).first().click().catch(() => {});
  const box = p.getByPlaceholder(/search/i).first();
  await box.fill(q);
  await p.waitForTimeout(900);
  await p.locator("button, li").filter({ hasText: /Somnath Roy/ }).first().click();
  await p.waitForTimeout(500);
};

/** [file, tab, viewport, steps(page), fullPage] */
const SHOTS = [
  ["who", "who", DESKTOP, null, true],
  ["who-top", "who", DESKTOP, null, false],
  ["who-change-mode", "who", DESKTOP, async (p) => {
    await p.getByRole("radio", { name: /Everyone except my list/ }).click();
    await p.waitForSelector("[data-testid='messages-reason']");
    await reason(p, "Open to everyone except people I name");
  }, false],
  ["words", "words", DESKTOP, null, true],
  ["held", "held", DESKTOP, null, false],
  ["chats", "chats", DESKTOP, async (p) => {
    await pick(p, "Member", "Som");
    await p.waitForSelector("[data-testid='messages-reason']");
    await reason(p, "Report about this member");
    await p.getByRole("button", { name: "Show chats" }).click();
    await p.waitForSelector("[data-testid='messages-chat-row']");
    await p.waitForTimeout(400);
  }, false],
  ["held-reader", "held", DESKTOP, async (p) => {
    await p.getByRole("button", { name: /Read and decide/ }).first().click();
    await p.waitForSelector("[data-testid='messages-reason']");
    await reason(p, "Held by the word guard: reviewing");
    await p.getByRole("button", { name: "Open and log" }).click();
    await p.waitForSelector("[data-testid='messages-chat-reader']");
    await p.waitForTimeout(500);
  }, false],
  ["history", "history", DESKTOP, null, true],
  ["who-phone", "who", PHONE, null, true],
  ["words-phone", "words", PHONE, null, false],
  ["held-phone", "held", PHONE, null, false],
];

let failed = false;
try {
  await waitForServer();
  const browser = await chromium.launch();
  for (const [name, tab, viewport, steps, fullPage] of SHOTS) {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, reducedMotion: "reduce", isMobile: viewport.width < 600, hasTouch: viewport.width < 600 });
    const page = await context.newPage();
    const missing = [];
    page.on("console", (m) => { if (/NO FIXTURE/.test(m.text())) missing.push(m.text().slice(0, 160)); });
    await page.goto(`${BASE}/uiharness.html?scene=screen-admin-messages&strict=0&tab=${tab}`, { waitUntil: "load", timeout: 180000 });
    // Phones open the admin menu first (MobileAdminNav); tap "Messages" as an admin would.
    if (viewport.width < 768) {
      await page.getByRole("button", { name: /^Messages$/ }).first().click({ timeout: 60000 });
    }
    await page.waitForSelector("[data-testid='admin-messages']", { timeout: 60000 });
    await page.waitForSelector("[data-testid='messages-status']", { timeout: 60000 });
    await page.waitForTimeout(1000);
    if (steps) await steps(page);
    await page.screenshot({ path: join(OUT, `admin-messages-${name}-REAL.png`), fullPage });
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

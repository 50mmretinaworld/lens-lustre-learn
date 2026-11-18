#!/usr/bin/env node
/**
 * STORY CAPTION + @NAME (Owner 18 Nov 2026) — `node tools/uishot/story-caption-shots.mjs <out-dir>`
 *
 * Photographs the REAL StoryViewer in app mode (`?native=1`) at phone width
 * 390, Chromium: a story made from a long post (`&stories=1&storylong=1`,
 * storySample.ts) — two-line caption, the dark fade, comments with @all and a
 * member mention — and the full text after "more".
 * Fails if the caption is not clamped, if "more" is missing, or if any stored
 * mention form "@[" is on screen.
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2];
if (!OUT) throw new Error("usage: story-caption-shots.mjs <out-dir>");
mkdirSync(OUT, { recursive: true });

const PORT = Number(process.env.SHOT_PORT ?? 5297);
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

let failed = false;
const fail = (m) => { console.error(m); failed = true; };
try {
  await waitForServer();
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, reducedMotion: "reduce", isMobile: true, hasTouch: true });
  const page = await context.newPage();
  await page.goto(`${BASE}/uiharness.html?scene=screen-feed&strict=0&native=1&stories=1&storylong=1`, { waitUntil: "load", timeout: 180000 });
  await page.getByText("Dipannita Sen").first().click({ timeout: 60000 });
  await page.waitForSelector("[data-testid='story-caption']", { timeout: 30000 });
  await page.getByRole("button", { name: "Pause" }).click();
  // the story photo is remote (picsum): wait until it has really decoded, never a fixed guess
  await page.waitForFunction(() => [...document.images].some((i) => /picsum/.test(i.currentSrc || i.src) && i.complete && i.naturalWidth > 600), null, { timeout: 60000 })
    .catch(() => fail("the story photo never loaded — the picture would be black"));
  await page.waitForTimeout(800);
  const raw = async () => (await page.locator("body").innerText()).includes("@[");
  const clamp = await page.locator("[data-testid='story-caption'] p").evaluate((el) => getComputedStyle(el).webkitLineClamp);
  if (String(clamp) !== "2") fail(`caption line clamp is ${clamp}, expected 2`);
  if (!(await page.locator("[data-testid='story-caption-more']").count())) fail("no 'more' on a long caption");
  if (await raw()) fail("a stored mention @[…](…) is on screen");
  await page.screenshot({ path: join(OUT, "story-NEW-caption-REAL.png") });
  console.log("story-NEW-caption: saved");

  await page.getByTestId("story-caption-more").click();
  await page.waitForSelector("[data-testid='story-caption-full']", { timeout: 10000 });
  await page.waitForTimeout(600);
  if (await raw()) fail("a stored mention @[…](…) is on screen in the full text");
  await page.screenshot({ path: join(OUT, "story-NEW-more-REAL.png") });
  console.log("story-NEW-more: saved");
  await browser.close();
} catch (e) {
  console.error(e);
  failed = true;
} finally {
  server.kill();
}
process.exit(failed ? 1 : 0);

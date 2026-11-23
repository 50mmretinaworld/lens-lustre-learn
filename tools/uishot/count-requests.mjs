#!/usr/bin/env node
/**
 * N3 · HOW MANY SERVER REQUESTS DOES EACH SCREEN MAKE? — `node tools/uishot/count-requests.mjs [scene …]`
 *
 * Opens REAL screens in the UI harness (fake backend, real app code) and counts every Supabase
 * request each screen sends in its first 8 s, grouped by what it asks for. The harness answers
 * instantly, so this counts requests, not time; time comes from client_telemetry (N5).
 */
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const SCENES = process.argv.slice(2).length ? process.argv.slice(2) : ["screen-feed", "screen-wall", "screen-notifications", "screen-messages"];
const PORT = Number(process.env.SHOT_PORT ?? 5297);
const BASE = `http://127.0.0.1:${PORT}`;
const viteBin = join(dirname(createRequire(import.meta.url).resolve("vite/package.json")), "bin", "vite.js");
const server = spawn(process.execPath, [viteBin, "--host", "127.0.0.1", "--port", String(PORT), "--strictPort"], {
  stdio: "ignore",
  env: { ...process.env, VITE_SUPABASE_URL: "https://testprojectref0000x.supabase.co", VITE_SUPABASE_PUBLISHABLE_KEY: "test-publishable-key-not-real", VITE_SUPABASE_PROJECT_ID: "testprojectref0000x" },
});
async function waitForServer() {
  for (let i = 0; i < 120; i++) { try { if ((await fetch(`${BASE}/uiharness.html`)).ok) return; } catch { /* not yet */ } await new Promise((r) => setTimeout(r, 1000)); }
  throw new Error("vite did not start");
}
try {
  await waitForServer();
  const browser = await chromium.launch();
  for (const scene of SCENES) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    await page.addInitScript((detail) => {
      const w = window;
      w.__reqs = [];
      let inner = w.fetch;
      Object.defineProperty(w, "fetch", {
        configurable: true,
        get() { return (input, init) => {
          const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
          if (/testprojectref0000x\.supabase\.co/.test(url)) {
            const u = new URL(url);
            const name = u.pathname.replace("/rest/v1/", "").replace("/functions/v1/", "fn:").replace("/storage/v1/", "storage:");
            if (detail) {
              // DETAIL=1: the exact ask (query + body) and the app files that sent it — tells a true repeat from a different read.
              const body = typeof init?.body === "string" ? init.body.slice(0, 80) : "";
              const from = (new Error().stack ?? "").split("\n").map((l) => (l.match(/\/src\/([^?:)]+)/) ?? [])[1])
                .filter((f) => f && !/integrations\/supabase/.test(f)).slice(0, 3).join(" < ");
              w.__reqs.push(`${name}${decodeURIComponent(u.search).slice(0, 100)} ${body} ← ${from}`);
            } else w.__reqs.push(name);
          }
          return inner(input, init);
        }; },
        set(v) { inner = v; },
      });
    }, process.env.DETAIL === "1");
    page.on("console", (m) => { if (m.text().startsWith("DBGINIT")) console.log(m.text()); });
    await page.goto(`${BASE}/uiharness.html?scene=${scene}&strict=0`, { waitUntil: "load", timeout: 180000 });
    await page.waitForTimeout(8000);
    const reqs = await page.evaluate(() => window.__reqs);
    const counts = {};
    for (const r of reqs) counts[r] = (counts[r] ?? 0) + 1;
    console.log(`\n${scene}: ${reqs.length} requests`);
    for (const [k, n] of Object.entries(counts).sort((a, b) => b[1] - a[1])) console.log(`  ${String(n).padStart(3)}  ${k}`);
    await page.close();
  }
  await browser.close();
} finally {
  server.kill();
}

#!/usr/bin/env node
// App Store Connect API helper for .github/workflows/ios-build.yml (Owner 23 Nov 2026: "build the system properly").
// Uses the App Store Connect key already saved in GitHub (APP_STORE_KEY_ID / APP_STORE_ISSUER_ID / APP_STORE_KEY_BASE64),
// so these Apple-side steps are never done by hand again:
//
//   node tools/ios/asc-setup.mjs app-id
//       → prints the app's numeric Apple ID (for the iOS "Update available" prompt). Prints nothing if not found.
//   node tools/ios/asc-setup.mjs profile <cert-serial-hex> <out.mobileprovision> [push]
//       → finds the Distribution certificate with that serial, (with "push") turns on the Push Notifications capability
//         for the bundle id, and writes an ACTIVE App Store profile for bundle id + certificate. The profile is named
//         "50mm Retina World App Store CI"; it is reused while valid (and, with push, while it carries aps-environment),
//         otherwise deleted and made again. Only this CI-named profile is ever deleted.
//
// Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8), BUNDLE_ID. Never prints the key or a token.
// Plain Node 22, no packages. Exit 1 with a readable ::error:: line on any Apple refusal.
import { createSign } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const API = "https://api.appstoreconnect.apple.com/v1";
const PROFILE_NAME = "50mm Retina World App Store CI";
const EXTENSION_PROFILE_NAME = "50mm Retina World Notification Service CI";
const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID } = process.env;

function fail(msg) {
  console.error(`::error::${msg}`);
  process.exit(1);
}
if (!ASC_KEY_ID || !ASC_ISSUER_ID || !ASC_KEY_PATH || !BUNDLE_ID) fail("asc-setup: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH and BUNDLE_ID are required");

const b64url = (buf) => Buffer.from(buf).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

function token() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: ASC_KEY_ID, typ: "JWT" }));
  const body = b64url(JSON.stringify({ iss: ASC_ISSUER_ID, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }));
  const signer = createSign("SHA256");
  signer.update(`${head}.${body}`);
  const sig = signer.sign({ key: readFileSync(ASC_KEY_PATH, "utf8"), dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${b64url(sig)}`;
}

async function call(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return null;
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not json */ }
  if (!res.ok) {
    const detail = json?.errors?.map((e) => `${e.code ?? ""} ${e.title ?? ""}: ${e.detail ?? ""}`).join(" | ") || text.slice(0, 300);
    const role = res.status === 403 ? " (403: the saved App Store Connect key's role is not allowed to do this — it needs the Admin role, or do this step on developer.apple.com)" : "";
    fail(`App Store Connect ${method} ${path.split("?")[0]} → ${res.status}${role}: ${detail}`);
  }
  return json;
}

const normSerial = (s) => String(s || "").replace(/^serial=/i, "").replace(/[^0-9a-f]/gi, "").toUpperCase().replace(/^0+/, "");

async function bundleId() {
  const r = await call("GET", `/bundleIds?filter[identifier]=${encodeURIComponent(BUNDLE_ID)}&limit=20`);
  const hit = (r.data || []).find((b) => b.attributes?.identifier === BUNDLE_ID);
  if (!hit) fail(`No bundle id ${BUNDLE_ID} in the Apple developer account`);
  return hit;
}

async function appId() {
  const r = await call("GET", `/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}&limit=5`);
  const hit = (r.data || []).find((a) => a.attributes?.bundleId === BUNDLE_ID);
  if (hit?.id) process.stdout.write(hit.id);
}

async function ensurePush(bid) {
  const caps = await call("GET", `/bundleIds/${bid.id}/bundleIdCapabilities`);   // this relationship refuses ?limit
  if ((caps.data || []).some((c) => c.attributes?.capabilityType === "PUSH_NOTIFICATIONS")) {
    console.log("Push Notifications capability: already on");
    return;
  }
  await call("POST", "/bundleIdCapabilities", {
    data: {
      type: "bundleIdCapabilities",
      attributes: { capabilityType: "PUSH_NOTIFICATIONS" },
      relationships: { bundleId: { data: { type: "bundleIds", id: bid.id } } },
    },
  });
  console.log("Push Notifications capability: turned ON for " + BUNDLE_ID);
}

async function certificateFor(serial) {
  const want = normSerial(serial);
  const r = await call("GET", "/certificates?limit=200");
  const hit = (r.data || []).find((c) => normSerial(c.attributes?.serialNumber) === want);
  if (!hit) fail(`The Distribution certificate in BUILD_CERTIFICATE_BASE64 (serial ${want}) is not in the Apple developer account (revoked or another team)`);
  console.log(`Certificate: ${hit.attributes.certificateType} "${hit.attributes.name}" expires ${hit.attributes.expirationDate}`);
  return hit;
}

/** The notification service extension's App ID: made once, then found. */
async function extensionBundleId() {
  const r = await call("GET", `/bundleIds?filter[identifier]=${encodeURIComponent(BUNDLE_ID)}&limit=20`);
  const hit = (r.data || []).find((b) => b.attributes?.identifier === BUNDLE_ID);
  if (hit) return hit;
  const made = await call("POST", "/bundleIds", {
    data: { type: "bundleIds", attributes: { identifier: BUNDLE_ID, name: "50mm Retina World Notification Service", platform: "IOS" } },
  });
  console.log("App ID registered: " + BUNDLE_ID);
  return made.data;
}

async function profile(serial, outPath, wantPush, extension = false) {
  if (!serial || !outPath) fail("usage: asc-setup.mjs profile <cert-serial-hex> <out.mobileprovision> [push]");
  const name = extension ? EXTENSION_PROFILE_NAME : PROFILE_NAME;
  const bid = extension ? await extensionBundleId() : await bundleId();
  if (wantPush) await ensurePush(bid);
  const cert = await certificateFor(serial);

  const existing = await call("GET", `/profiles?filter[name]=${encodeURIComponent(name)}&limit=20`);
  for (const p of existing.data || []) {
    const content = Buffer.from(p.attributes?.profileContent || "", "base64");
    const fresh = p.attributes?.profileState === "ACTIVE"
      && new Date(p.attributes?.expirationDate || 0).getTime() > Date.now() + 7 * 86400_000
      && (!wantPush || content.includes("aps-environment"))
      && content.includes(BUNDLE_ID);
    if (fresh) {
      writeFileSync(outPath, content);
      console.log(`Profile: reused "${name}" (${p.attributes.uuid}), expires ${p.attributes.expirationDate}`);
      return;
    }
    await call("DELETE", `/profiles/${p.id}`);
    console.log(`Profile: removed out-of-date "${name}" (${p.attributes?.uuid ?? p.id})`);
  }

  const made = await call("POST", "/profiles", {
    data: {
      type: "profiles",
      attributes: { name, profileType: "IOS_APP_STORE" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bid.id } },
        certificates: { data: [{ type: "certificates", id: cert.id }] },
      },
    },
  });
  const content = Buffer.from(made.data.attributes.profileContent, "base64");
  if (wantPush && !content.includes("aps-environment")) fail("The new App Store profile has no aps-environment — Push is not on for the App ID yet");
  writeFileSync(outPath, content);
  console.log(`Profile: made "${name}" (${made.data.attributes.uuid}), expires ${made.data.attributes.expirationDate}`);
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === "app-id") await appId();
else if (cmd === "profile") await profile(args[0], args[1], args[2] === "push");
else if (cmd === "extension-profile") await profile(args[0], args[1], false, true);   // BUNDLE_ID = the extension's
else fail("usage: asc-setup.mjs app-id | profile <cert-serial-hex> <out.mobileprovision> [push] | extension-profile <cert-serial-hex> <out>");

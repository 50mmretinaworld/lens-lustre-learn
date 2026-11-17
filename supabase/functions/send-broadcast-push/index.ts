import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildBroadcastMessage, legacyTapTarget, safeLink, type BroadcastContent } from "../_shared/broadcastMessage.ts";
import { buildFcmMessage, isSafeImageUrl } from "../_shared/pushMessage.ts";
import { fcmErrorCode } from "../_shared/pushReceipts.ts";
import { sendWithRetry } from "../_shared/pushRetry.ts";
import { isDeadToken, fcmDetailCode } from "../_shared/pushTokens.ts";
import { laneImageHosts } from "../_shared/laneImageHosts.ts";

// ─────────────────────────────────────────────────────────────────────────────
// send-broadcast-push — the admin push (PUSH CENTRE PN1, 20261116_1500).
//
// Callers and what each may do:
//   admin JWT  { broadcast_id, test: true }  → the admin's OWN phones only,
//              title prefixed "Test · "; nothing recorded on the broadcast.
//   admin JWT  { broadcast_id }              → send now: claims the row
//              (scheduled → sending, once) and sends to its audience.
//   job engine x-internal-secret { broadcast_id, job_id, attempt } → the same
//              claim at the scheduled time. The secret cannot write or choose a
//              message: push_broadcast_claim only releases a row an admin
//              scheduled that is due, and only once.
//   admin JWT  { title, body?, image_url?, link?, dry_run? } → the old one-box
//              page (kept until the new page is live everywhere): everyone.
//
// Each member gets one receipt row (notification_deliveries.broadcast_id);
// the receipt id goes in the message, so the app's existing "opened" report
// counts opens. A token is removed only when FCM blames the token itself
// (isDeadToken) — a bad message never removes good phones again.
//
// Secrets: FCM_SERVICE_ACCOUNT, PUSH_INTERNAL_SECRET (same as send-push).
// ─────────────────────────────────────────────────────────────────────────────

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (payload: unknown, status = 200) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

function b64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const s = btoa(String.fromCharCode(...bytes));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Exchange the service account for a short-lived OAuth2 token (RS256 JWT). */
// deno-lint-ignore no-explicit-any
async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const signingInput = `${header}.${claim}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput)),
  );
  const jwt = `${signingInput}.${b64url(sig)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const out = await res.json();
  if (!out.access_token) throw new Error("FCM token exchange failed: " + JSON.stringify(out));
  return out.access_token;
}

interface Target { delivery_id: number | null; token: string; caps: string[] | null }
interface DeviceResult { delivery_id: number | null; token: string; ok: boolean; dead: boolean; code: string }

/** Send one message per device, 20 at a time, each with one retry on a temporary failure. */
async function sendEach(
  targets: Target[],
  build: (t: Target) => unknown,
  fcm: { endpoint: string; accessToken: string },
): Promise<DeviceResult[]> {
  const out: DeviceResult[] = [];
  const BATCH = 20;
  for (let i = 0; i < targets.length; i += BATCH) {
    const slice = targets.slice(i, i + BATCH);
    await Promise.all(slice.map(async (t) => {
      const post = () => fetch(fcm.endpoint, {
        method: "POST",
        headers: { Authorization: `Bearer ${fcm.accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ message: build(t) }),
      });
      try {
        const r = await sendWithRetry(post);
        if (r.ok) {
          out.push({ delivery_id: t.delivery_id, token: t.token, ok: true, dead: false, code: "" });
          return;
        }
        const text = await r.text();
        const code = fcmDetailCode(text) || fcmErrorCode(text);
        out.push({ delivery_id: t.delivery_id, token: t.token, ok: false, dead: isDeadToken(r.status, text), code: `${r.status} ${code}` });
        console.error("FCM broadcast send failed", r.status, code);
      } catch (err) {
        out.push({ delivery_id: t.delivery_id, token: t.token, ok: false, dead: false, code: "NETWORK" });
        console.error("FCM broadcast network error", (err as Error)?.message);
      }
    }));
  }
  return out;
}

const BROADCAST_COLUMNS = "id, title, body, image_url, images, link, countdown_until, actions, status";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(supabaseUrl, serviceKey);

    // deno-lint-ignore no-explicit-any
    const input: any = await req.json().catch(() => ({}));
    const broadcastId = Number(input?.broadcast_id);
    const hasBroadcast = Number.isSafeInteger(broadcastId) && broadcastId > 0;

    // ── who is calling ──
    const internalSecret = Deno.env.get("PUSH_INTERNAL_SECRET");
    const fromEngine = !!internalSecret && req.headers.get("x-internal-secret") === internalSecret;
    let adminId: string | null = null;
    if (!fromEngine) {
      const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
      if (!jwt) return json({ error: "Unauthorized" }, 401);
      const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
      const user = userData?.user;
      if (userErr || !user) return json({ error: "Unauthorized", detail: userErr?.message ?? "no user for token" }, 401);
      const { data: role } = await admin
        .from("user_roles").select("role")
        .eq("user_id", user.id).eq("role", "admin").maybeSingle();
      if (!role) return json({ error: "Admin only" }, 403);
      adminId = user.id;
    }
    if (fromEngine && !hasBroadcast) return json({ error: "broadcast_id required" }, 400);

    const fcmReady = async () => {
      const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
      if (!saRaw) throw new Error("FCM_SERVICE_ACCOUNT secret is not set");
      const sa = JSON.parse(saRaw);
      return {
        endpoint: `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
        accessToken: await getAccessToken(sa),
      };
    };
    const prune = async (results: DeviceResult[]) => {
      const dead = results.filter((r) => r.dead).map((r) => r.token);
      if (dead.length) await admin.from("push_tokens").delete().in("token", dead);
      return dead.length;
    };

    // ── the old one-box page: everyone, immediately ──
    if (!hasBroadcast) {
      const { title, body, image_url, link, dry_run } = input ?? {};
      if (!title || !String(title).trim()) return json({ error: "A title is required" }, 400);
      const { data: tokens, error: tokErr } = await admin.from("push_tokens").select("token, user_id");
      if (tokErr) return json({ error: tokErr.message }, 500);
      const devices = tokens ?? [];
      const people = new Set(devices.map((t: { user_id: string }) => t.user_id)).size;
      if (dry_run) return json({ success: true, dry_run: true, devices: devices.length, people, sent: 0 });
      if (devices.length === 0) return json({ success: true, sent: 0, devices: 0, people: 0, note: "No devices are registered yet" });
      const fcm = await fcmReady();
      const imageHosts = image_url ? laneImageHosts() : [];
      // Owner bug 16 Nov: apps ≤ 1.2.49 ignore `link`; legacyTapTarget also sends
      // it as a type their own table opens (see broadcastMessage.ts).
      const tapLink = safeLink(typeof link === "string" ? link.trim() : null);
      const results = await sendEach(
        devices.map((t: { token: string }) => ({ delivery_id: null, token: t.token, caps: [] })),
        (t) => buildFcmMessage({
          token: t.token, title: String(title), body: body ? String(body) : "",
          data: { ...legacyTapTarget(tapLink), ...(tapLink ? { link: tapLink } : {}) },
          imageUrl: image_url ? String(image_url) : null, imageHosts,
        }),
        fcm,
      );
      const pruned = await prune(results);
      const errors = [...new Set(results.filter((r) => !r.ok).map((r) => r.code))].slice(0, 3);
      return json({
        success: true, sent: results.filter((r) => r.ok).length, devices: devices.length, people, pruned,
        ...(errors.length ? { errors } : {}),
      });
    }

    const { data: b, error: bErr } = await admin.from("push_broadcasts").select(BROADCAST_COLUMNS)
      .eq("id", broadcastId).maybeSingle();
    if (bErr) return json({ error: bErr.message }, 500);
    if (!b) return json({ error: "No such message" }, 404);
    const content = b as unknown as BroadcastContent & { status: string };
    const imageHosts = laneImageHosts();
    // a picture this lane may not send is left out of the push — say so, never silently
    const pictureLeftOut = !!content.image_url && !isSafeImageUrl(content.image_url, imageHosts);

    // ── test: the admin's own phones only ──
    if (input?.test === true) {
      if (!adminId) return json({ error: "A test is sent by an admin" }, 403);
      const { data: mine, error: mErr } = await admin.from("push_tokens").select("token, caps").eq("user_id", adminId);
      if (mErr) return json({ error: mErr.message }, 500);
      if (!mine?.length) {
        return json({ success: true, test: true, devices: 0, sent: 0,
          note: "Your account has no phone registered. Open the 50mm Retina app on your phone, sign in, and allow notifications." });
      }
      const fcm = await fcmReady();
      const results = await sendEach(
        mine.map((t: { token: string; caps: string[] | null }) => ({ delivery_id: null, token: t.token, caps: t.caps })),
        (t) => buildBroadcastMessage(content, t, { imageHosts, test: true }),
        fcm,
      );
      const removed = await prune(results);
      return json({
        success: true, test: true, devices: results.length, sent: results.filter((r) => r.ok).length, removed,
        errors: [...new Set(results.filter((r) => !r.ok).map((r) => r.code))].slice(0, 3),
        ...(pictureLeftOut ? { picture_left_out: true } : {}),
      });
    }

    // ── send: claim once, then every device page by page ──
    const { data: claimed, error: cErr } = await admin.rpc("push_broadcast_claim", { _id: broadcastId });
    if (cErr) return json({ error: cErr.message }, 500);
    if (claimed !== true) {
      // not due, cancelled, or already sent by the other caller — a success for the job engine
      return json({ success: true, skipped: content.status });
    }

    const results: DeviceResult[] = [];
    // a short CODE for the record (push_broadcast_finish._error) — never the raw error text
    let failure: string | null = null;
    let stage: "NOT_CONFIGURED" | "GOOGLE_SIGN_IN" | "DATABASE" | "SEND_STOPPED" = "NOT_CONFIGURED";
    try {
      if (!Deno.env.get("FCM_SERVICE_ACCOUNT")) throw new Error("FCM_SERVICE_ACCOUNT secret is not set");
      stage = "GOOGLE_SIGN_IN";
      const fcm = await fcmReady();
      let after = 0;
      for (;;) {
        // 200 members a page: their devices stay far under the API's row cap
        stage = "DATABASE";
        const { data: page, error: pErr } = await admin.rpc("push_broadcast_targets",
          { _id: broadcastId, _after: after, _limit: 200 });
        if (pErr) throw new Error(pErr.message);
        const rows = (page ?? []) as Array<{ delivery_id: number; token: string; caps: string[] | null }>;
        if (rows.length === 0) break;
        stage = "SEND_STOPPED";
        results.push(...await sendEach(
          rows.map((r) => ({ delivery_id: r.delivery_id, token: r.token, caps: r.caps })),
          (t) => buildBroadcastMessage(content, t, { imageHosts, deliveryId: t.delivery_id }),
          fcm,
        ));
        after = Math.max(...rows.map((r) => r.delivery_id));
      }
    } catch (err) {
      failure = stage;
      console.error("send-broadcast-push stopped part-way", stage, (err as Error)?.message);
    }

    // one outcome per member receipt; a dead token is removed and counted
    const byReceipt = new Map<number, { d: number; ok: number; failed: number; removed: number; error: string }>();
    for (const r of results) {
      if (r.delivery_id === null) continue;
      const e = byReceipt.get(r.delivery_id) ?? { d: r.delivery_id, ok: 0, failed: 0, removed: 0, error: "" };
      if (r.ok) e.ok++;
      else {
        e.failed++;
        if (r.dead) e.removed++;
        e.error = e.error || r.code;
      }
      byReceipt.set(r.delivery_id, e);
    }
    const removed = await prune(results);
    const { error: fErr } = await admin.rpc("push_broadcast_finish",
      { _id: broadcastId, _results: [...byReceipt.values()], _error: failure });
    if (fErr) console.error("push_broadcast_finish failed", fErr.message);

    return json({
      success: failure === null,
      sent: results.filter((r) => r.ok).length,
      failed: results.filter((r) => !r.ok).length,
      removed,
      devices: results.length,
      members: byReceipt.size,
      ...(failure ? { stopped: failure } : {}),
      ...(pictureLeftOut ? { picture_left_out: true } : {}),
    });
  } catch (err) {
    console.error("send-broadcast-push error:", err);
    return json({ error: (err as Error).message }, 500);
  }
});

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─────────────────────────────────────────────────────────────────────────
// message-photo-verify — M25 (20261118_3500). Is a chat photo REALLY a photo?
//
// The browser re-encodes every photo to WebP, but a member can call the upload API directly and name any bytes "image/webp".
// After each chat photo is attached, the job engine (job kind message.photo_verify, queued by a trigger on
// message_attachments) calls this function once with { attachment_id }. It reads the first bytes of the stored file and checks
// the real signature: JPEG (FF D8 FF), PNG (89 50 4E 47 0D 0A 1A 0A) or WebP (RIFF....WEBP). A file that is not one of them is
// deleted from storage at once and its photo is marked removed (shown as "Photo no longer available").
//
// Caller: ONLY the job engine (x-internal-secret = PUSH_INTERNAL_SECRET). The function takes an attachment id and nothing else,
// and can only ever DELETE a file that fails the check.
// ─────────────────────────────────────────────────────────────────────────

const json = (payload: unknown, status = 200) =>
  new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json" } });

function isRealImage(b: Uint8Array): boolean {
  const jpeg = b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  const png = b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a;
  const webp = b.length >= 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50;
  return jpeg || png || webp;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const internalSecret = Deno.env.get("PUSH_INTERNAL_SECRET");
  if (!internalSecret || req.headers.get("x-internal-secret") !== internalSecret) {
    return json({ error: "Unauthorized" }, 401);
  }

  // deno-lint-ignore no-explicit-any
  const input: any = await req.json().catch(() => ({}));
  const id = typeof input?.attachment_id === "string" ? input.attachment_id : "";
  if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "attachment_id required" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: path, error: pathErr } = await admin.rpc("message_photo_to_verify", { _id: id });
  if (pathErr) return json({ error: "could not look up the photo", detail: pathErr.message }, 500);
  if (!path || typeof path !== "string") return json({ ok: true, skipped: "nothing to check" });

  const { data: file, error: dlErr } = await admin.storage.from("message-photos").download(path);
  if (dlErr || !file) {
    // Not found yet / transient: let the engine retry. After its retries the photo simply stays unchecked.
    return json({ error: "could not read the file", detail: dlErr?.message ?? "no file" }, 500);
  }
  const head = new Uint8Array(await file.slice(0, 16).arrayBuffer());
  const ok = isRealImage(head);

  if (!ok) {
    const { error: rmErr } = await admin.storage.from("message-photos").remove([path]);
    if (rmErr) return json({ error: "could not delete the invalid file", detail: rmErr.message }, 500);
  }
  const { error: markErr } = await admin.rpc("message_photo_verify_mark", { _id: id, _ok: ok });
  if (markErr) return json({ error: "could not record the result", detail: markErr.message }, 500);
  return json({ ok: true, valid: ok });
});

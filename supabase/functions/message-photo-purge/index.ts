import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─────────────────────────────────────────────────────────────────────────
// message-photo-purge — M19 (20261118_3100). Chat photos live 30 days on the server.
//
// Caller: ONLY the job engine (job kind message.photo_purge), which sends x-internal-secret = PUSH_INTERNAL_SECRET
// (the same vault secret as push.send). Nobody else can run it: no secret, no answer. It takes no input and
// can only do one thing — delete chat photos that are already older than 30 days, then mark them expired.
//
// Order matters: the file is deleted from storage FIRST and a photo is marked expired only when its file is gone,
// so a failed delete is simply tried again the next day and a picture is never "expired" while still on the server.
// The message text and the message row stay for ever.
// ─────────────────────────────────────────────────────────────────────────

const json = (payload: unknown, status = 200) =>
  new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json" } });

const BATCH = 200;
const MAX_BATCHES = 10; // up to 2,000 photos per run; the rest waits for tomorrow

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const internalSecret = Deno.env.get("PUSH_INTERNAL_SECRET");
  if (!internalSecret || req.headers.get("x-internal-secret") !== internalSecret) {
    return json({ error: "Unauthorized" }, 401);
  }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let deleted = 0;
  for (let i = 0; i < MAX_BATCHES; i++) {
    const { data: due, error: dueErr } = await admin.rpc("message_photos_due", { _limit: BATCH });
    if (dueErr) return json({ error: "could not list due photos", detail: dueErr.message, deleted, failed }, 500);
    const rows: Array<{ id: string; path: string }> = Array.isArray(due) ? due : [];
    if (rows.length === 0) break;

    const { error: rmErr } = await admin.storage.from("message-photos").remove(rows.map((r) => r.path));
    if (rmErr) return json({ error: "storage delete failed", detail: rmErr.message, deleted }, 500);

    // A path that was already gone counts as done too (nothing is left on the server), so mark every row of the batch.
    const { error: markErr } = await admin.rpc("message_photos_mark_expired", { _ids: rows.map((r) => r.id) });
    if (markErr) return json({ error: "could not mark photos expired", detail: markErr.message, deleted }, 500);
    deleted += rows.length;
    if (rows.length < BATCH) break;
  }
  return json({ ok: true, deleted });
});

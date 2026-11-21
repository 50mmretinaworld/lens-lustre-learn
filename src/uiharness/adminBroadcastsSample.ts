/**
 * M12 harness sample — what the Broadcast admin rpcs answer: one broadcast going out right now (5,000 members, 10 batches,
 * 3 done), one finished, one scheduled, a draft and a withdrawn one; the per-batch and per-member numbers; the audience count.
 * Answers only when __harnessAdminMessages is set (scene screen-admin-messages, ?tab=broadcast).
 */
const t = (minAgo: number) => new Date(Date.UTC(2026, 10, 21, 9, 30) - minAgo * 60_000).toISOString();

interface SampleBc {
  id: number; title: string; status: string; created_at: string; body: string; photos: number; total_members: number | null; send_at: string | null;
  started_at: string | null; finished_at: string | null; sender_name: string; delivered: number; failed: number; read: number;
  batches_total: number; batches_done: number; push: boolean; audience: Record<string, unknown>;
}
const ROW = (o: Partial<SampleBc> & Pick<SampleBc, "id" | "title" | "status" | "created_at">): SampleBc => ({
  body: "", photos: 0, total_members: null, send_at: null, started_at: null, finished_at: null, sender_name: "Neil Basu", delivered: 0, failed: 0, read: 0,
  batches_total: 0, batches_done: 0, push: true, audience: { kind: "all" }, ...o,
});

const LIST = [
  ROW({ id: 7, title: "Welcome to private messages", body: "Hello! Private messages are now open. Say hi to a photographer you follow 📷 https://50mmretina.com/messages",
        status: "sending", total_members: 5000, created_at: t(18), started_at: t(16), delivered: 1488, failed: 12, read: 640, batches_total: 10, batches_done: 3, photos: 1 }),
  ROW({ id: 6, title: "Competition results are out", body: "The Street Life results are live. Congratulations to every finalist! 🏆", status: "done", total_members: 1240,
        audience: { kind: "active", days: 30 }, created_at: t(4300), started_at: t(4290), finished_at: t(4285), delivered: 1228, failed: 12, read: 805, batches_total: 3, batches_done: 3 }),
  ROW({ id: 8, title: "Weekend photo walk", body: "Join us on Saturday for the Kolkata photo walk. Details inside.", status: "scheduled", total_members: 320,
        audience: { kind: "role", role: "registered_photographer" }, created_at: t(120), send_at: t(-1500), started_at: t(-1500), batches_total: 1, batches_done: 0 }),
  ROW({ id: 5, title: "Photography tips (draft)", body: "Five quick tips for sharper portraits at f/1.8.", status: "draft", created_at: t(2000), audience: { kind: "members", ids: ["a", "b", "c"] } }),
  ROW({ id: 4, title: "Maintenance notice", body: "The site will be slow for a few minutes tonight.", status: "withdrawn", total_members: 900, created_at: t(9000),
        started_at: t(8990), finished_at: t(8985), delivered: 0, failed: 0, read: 0, batches_total: 2, batches_done: 2 }),
];

export function sampleMessageBroadcasts(b: Record<string, unknown>) {
  const st = typeof b._status === "string" ? b._status : null;
  const rows = LIST.filter((r) => !st || r.status === st);
  const counts: Record<string, number> = {};
  for (const r of LIST) counts[String(r.status)] = (counts[String(r.status)] ?? 0) + 1;
  return { total: rows.length, counts, rows };
}

export function sampleBroadcastReport(b: Record<string, unknown>) {
  const row = LIST.find((r) => r.id === Number(b._id)) ?? LIST[0];
  const total = row.total_members ?? 0;
  const batches = Array.from({ length: row.batches_total }, (_, i) => {
    const seq = i + 1;
    const doneN = row.batches_done;
    const status = seq <= doneN ? (seq === 2 && row.id === 7 ? "done" : "done") : seq === doneN + 1 && row.status === "sending" ? "running" : row.status === "scheduled" ? "waiting" : "waiting";
    const size = total && seq === row.batches_total ? total - 500 * (row.batches_total - 1) : 500;
    const failed = status === "done" && row.id === 7 && seq === 2 ? 12 : status === "done" && row.id === 6 && seq === 3 ? 12 : 0;
    return {
      id: row.id * 100 + seq, seq, status, size, delivered: status === "done" ? size - failed : 0, failed, attempts: status === "waiting" ? 0 : seq === 2 && row.id === 7 ? 2 : 1,
      run_at: t(16 - i), started_at: status === "waiting" ? null : t(16 - i), finished_at: status === "done" ? t(15 - i) : null,
      last_error: failed > 0 ? "declined this chat" : null,
    };
  });
  return {
    broadcast: {
      id: row.id, title: row.title, body: row.body, photos: row.photos ? [{ path: "data:sample", width: 900, height: 600 }] : [], audience: row.audience, push: row.push,
      status: row.status, sender_id: "11111111-1111-4111-8111-111111111111", batch_size: 500, batch_gap_seconds: 60, send_at: row.send_at,
      total_members: row.total_members, created_at: row.created_at, started_at: row.started_at, finished_at: row.finished_at,
    },
    totals: {
      audience: total, delivered: row.delivered, failed: row.failed, waiting: row.status === "sending" ? total - row.delivered - row.failed : row.status === "scheduled" ? total : 0,
      withdrawn: 0, read: row.read, unread: Math.max(row.delivered - row.read, 0),
    },
    batches,
    engine_on: true,
  };
}

const NAMES = ["Ananya Sen", "Rakesh Dutta", "Priya Nair", "Imran Qureshi", "Sandeep Kale", "Meera Iyer", "Tanmay Ghosh", "Lakshmi Rao", "Arjun Mehta", "Framo Grapher",
  "Somnath Roy", "Ranjana Bhattacharya", "Li Wei", "Debasish Paul", "Kavya Menon", "Omar Farooq", "Sneha Pillai", "Rohan Das", "Isha Kapoor", "Vikram Singh"];
const PEOPLE = NAMES.map((full_name, i) => {
  const status = i === 7 ? "failed" : i === 13 ? "failed" : i >= 17 ? "waiting" : "delivered";
  const read = status === "delivered" && i % 3 !== 2;
  return {
    user_id: `55555555-5555-4555-8555-${String(i).padStart(12, "0")}`, full_name, username: full_name.toLowerCase().replace(/[^a-z]/g, "").slice(0, 12), avatar_url: null,
    status, error: status === "failed" ? (i === 7 ? "blocked" : "declined this chat") : null, delivered_at: status === "delivered" ? t(15 - (i % 10)) : null,
    read, read_at: read ? t(10 - (i % 8)) : null,
  };
});

export function sampleBroadcastRecipients(b: Record<string, unknown>) {
  const filter = String(b._filter ?? "all");
  const needle = String(b._q ?? "").trim().toLowerCase();
  const lim = Number(b._limit ?? 25);
  const off = Number(b._offset ?? 0);
  const base = PEOPLE.filter((p) => !needle || `${p.full_name} ${p.username}`.toLowerCase().includes(needle));
  const shown = base.filter((p) => (filter === "delivered" ? p.status === "delivered" : filter === "failed" ? p.status === "failed" : filter === "read" ? p.read
    : filter === "unread" ? p.status === "delivered" && !p.read : filter === "waiting" ? p.status === "waiting" : true));
  return {
    total: shown.length,
    counts: {
      all: base.length, delivered: base.filter((p) => p.status === "delivered").length, failed: base.filter((p) => p.status === "failed").length,
      read: base.filter((p) => p.read).length, unread: base.filter((p) => p.status === "delivered" && !p.read).length, waiting: base.filter((p) => p.status === "waiting").length,
    },
    rows: shown.slice(off, off + lim),
  };
}

export function sampleBroadcastAudience(b: Record<string, unknown>) {
  const a = (b._audience ?? {}) as { kind?: string; ids?: unknown[]; days?: number };
  const matched = a.kind === "members" ? (a.ids?.length ?? 0) : a.kind === "active" ? (a.days === 7 ? 1860 : 3120) : a.kind === "role" ? 320 : 5012;
  const left = a.kind === "members" ? 0 : Math.round(matched * 0.004);
  return { matched, will_receive: matched - left, left_out: left };
}

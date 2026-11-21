/**
 * M12 · Admin → Messages → Broadcast — data. Admin-only SECURITY DEFINER rpcs (20261118_2300); the database
 * checks admin itself and runs the sending: a broadcast is cut into batches (500 members each, a minute apart)
 * on the job engine, so nothing here "sends" in the browser — the page saves, asks the server to send, and reads
 * the numbers back: delivered / failed / read per batch and per member.
 */
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { queryKeys } from "@/lib/queryKeys";
import type { PushAudience } from "@/hooks/admin/usePushCentre";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export type BcStatus = "draft" | "scheduled" | "sending" | "paused" | "done" | "cancelled" | "withdrawn";
const STATUSES: BcStatus[] = ["draft", "scheduled", "sending", "paused", "done", "cancelled", "withdrawn"];
export type BcRecipientFilter = "all" | "delivered" | "read" | "unread" | "failed" | "waiting";

export interface BcPhoto { path: string; width: number | null; height: number | null }
export interface BcRow {
  id: number; title: string; body: string; status: BcStatus; audience: PushAudience; push: boolean; photos: number;
  total_members: number | null; created_at: string; send_at: string | null; started_at: string | null; finished_at: string | null;
  sender_name: string | null; delivered: number; failed: number; read: number; batches_total: number; batches_done: number;
}
export interface BcList { total: number; counts: Partial<Record<BcStatus, number>>; rows: BcRow[] }
export interface BcBatch {
  id: number; seq: number; status: "waiting" | "running" | "done" | "failed" | "cancelled"; size: number; delivered: number; failed: number;
  attempts: number; run_at: string | null; started_at: string | null; finished_at: string | null; last_error: string | null;
}
export interface BcReport {
  broadcast: { id: number; title: string; body: string; photos: BcPhoto[]; audience: PushAudience; push: boolean; status: BcStatus; sender_id: string;
              batch_size: number; batch_gap_seconds: number; send_at: string | null; total_members: number | null; created_at: string; started_at: string | null; finished_at: string | null };
  totals: { audience: number; delivered: number; failed: number; waiting: number; withdrawn: number; read: number; unread: number };
  batches: BcBatch[];
  engine_on: boolean;
}
export interface BcRecipient {
  user_id: string; full_name: string | null; username: string | null; avatar_url: string | null;
  status: "waiting" | "delivered" | "failed" | "withdrawn"; error: string | null; delivered_at: string | null; read: boolean; read_at: string | null;
}
export interface BcRecipients { total: number; counts: Record<BcRecipientFilter, number>; rows: BcRecipient[] }

const str = (v: unknown) => (typeof v === "string" ? v : null);
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v)) ? Number(v) : null);
const obj = (v: unknown) => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const status = (v: unknown): BcStatus => (STATUSES.includes(v as BcStatus) ? (v as BcStatus) : "draft");
const audience = (v: unknown): PushAudience => {
  const a = obj(v);
  if (a?.kind === "active") return { kind: "active", days: a.days === 30 ? 30 : 7 };
  if (a?.kind === "role" && typeof a.role === "string") return { kind: "role", role: a.role };
  if (a?.kind === "badge" && typeof a.badge === "string") return { kind: "badge", badge: a.badge };
  if (a?.kind === "members") return { kind: "members", ids: arr(a.ids).filter((x): x is string => typeof x === "string") };
  return { kind: "all" };
};

/** Shape guards: a malformed row is dropped, never the page. */
export function parseBroadcasts(data: unknown): BcList {
  const o = obj(data) ?? {};
  const c = obj(o.counts) ?? {};
  const counts: Partial<Record<BcStatus, number>> = {};
  for (const s of STATUSES) { const n = num(c[s]); if (n !== null) counts[s] = n; }
  const rows = arr(o.rows).flatMap((r) => {
    const m = obj(r);
    const id = num(m?.id);
    if (!m || id === null || typeof m.title !== "string" || typeof m.created_at !== "string") return [];
    return [{
      id, title: m.title, body: str(m.body) ?? "", status: status(m.status), audience: audience(m.audience), push: m.push !== false,
      photos: num(m.photos) ?? 0, total_members: num(m.total_members), created_at: m.created_at, send_at: str(m.send_at),
      started_at: str(m.started_at), finished_at: str(m.finished_at), sender_name: str(m.sender_name),
      delivered: num(m.delivered) ?? 0, failed: num(m.failed) ?? 0, read: num(m.read) ?? 0,
      batches_total: num(m.batches_total) ?? 0, batches_done: num(m.batches_done) ?? 0,
    }];
  });
  return { total: num(o.total) ?? rows.length, counts, rows };
}

export function parseBroadcastReport(data: unknown): BcReport | null {
  const o = obj(data);
  const b = obj(o?.broadcast);
  const t = obj(o?.totals) ?? {};
  const id = num(b?.id);
  if (!o || !b || id === null || typeof b.title !== "string") return null;
  const batches = arr(o.batches).flatMap((r) => {
    const x = obj(r);
    const bid = num(x?.id);
    if (!x || bid === null) return [];
    const st = ["waiting", "running", "done", "failed", "cancelled"].includes(x.status as string) ? (x.status as BcBatch["status"]) : "waiting";
    return [{ id: bid, seq: num(x.seq) ?? 0, status: st, size: num(x.size) ?? 0, delivered: num(x.delivered) ?? 0, failed: num(x.failed) ?? 0,
              attempts: num(x.attempts) ?? 0, run_at: str(x.run_at), started_at: str(x.started_at), finished_at: str(x.finished_at), last_error: str(x.last_error) }];
  });
  const photos = arr(b.photos).flatMap((p) => { const x = obj(p); return x && typeof x.path === "string" ? [{ path: x.path, width: num(x.width), height: num(x.height) }] : []; });
  return {
    broadcast: {
      id, title: b.title, body: str(b.body) ?? "", photos, audience: audience(b.audience), push: b.push !== false, status: status(b.status),
      sender_id: str(b.sender_id) ?? "", batch_size: num(b.batch_size) ?? 500, batch_gap_seconds: num(b.batch_gap_seconds) ?? 60, send_at: str(b.send_at),
      total_members: num(b.total_members), created_at: str(b.created_at) ?? "", started_at: str(b.started_at), finished_at: str(b.finished_at),
    },
    totals: { audience: num(t.audience) ?? 0, delivered: num(t.delivered) ?? 0, failed: num(t.failed) ?? 0, waiting: num(t.waiting) ?? 0,
              withdrawn: num(t.withdrawn) ?? 0, read: num(t.read) ?? 0, unread: num(t.unread) ?? 0 },
    batches,
    engine_on: o.engine_on === true,
  };
}

export function parseBroadcastRecipients(data: unknown): BcRecipients {
  const o = obj(data) ?? {};
  const c = obj(o.counts) ?? {};
  const rows = arr(o.rows).flatMap((r) => {
    const m = obj(r);
    if (!m || typeof m.user_id !== "string") return [];
    const st = ["waiting", "delivered", "failed", "withdrawn"].includes(m.status as string) ? (m.status as BcRecipient["status"]) : "waiting";
    return [{ user_id: m.user_id, full_name: str(m.full_name), username: str(m.username), avatar_url: str(m.avatar_url), status: st, error: str(m.error),
              delivered_at: str(m.delivered_at), read: m.read === true, read_at: str(m.read_at) }];
  });
  return {
    total: num(o.total) ?? rows.length,
    counts: { all: num(c.all) ?? 0, delivered: num(c.delivered) ?? 0, read: num(c.read) ?? 0, unread: num(c.unread) ?? 0, failed: num(c.failed) ?? 0, waiting: num(c.waiting) ?? 0 },
    rows,
  };
}

export function useBroadcasts(status: BcStatus | null, page: number, pageSize: number) {
  return useQuery({
    queryKey: queryKeys.adminBroadcasts(status ?? "all", page, pageSize),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_broadcasts", { _status: status, _limit: pageSize, _offset: page * pageSize });
      if (error) throw new Error(error.message ?? "Could not read the broadcasts");
      return parseBroadcasts(data);
    },
    placeholderData: keepPreviousData,
    // P10: while a broadcast is going out the list shows its progress; 30 s (the floor), only while the page is open.
    refetchInterval: 30_000,
    staleTime: 15_000,
  });
}

export function useBroadcastReport(id: number | null) {
  return useQuery({
    queryKey: queryKeys.adminBroadcastReport(id ?? 0),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_broadcast_report", { _id: id });
      if (error) throw new Error(error.message ?? "Could not read the report");
      const r = parseBroadcastReport(data);
      if (!r) throw new Error("The report came back empty");
      return r;
    },
    enabled: id !== null,
    // P10: 30 s (the floor) and only while the broadcast is still going out; a finished one is read once.
    refetchInterval: (q) => (q.state.data && ["sending", "scheduled"].includes(q.state.data.broadcast.status) ? 30_000 : false),
    staleTime: 10_000,
  });
}

export function useBroadcastRecipients(id: number | null, filter: BcRecipientFilter, q: string, page: number, pageSize: number) {
  return useQuery({
    queryKey: queryKeys.adminBroadcastRecipients(id ?? 0, filter, q, page, pageSize),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_broadcast_recipients", { _id: id, _filter: filter, _q: q.trim() || null, _limit: pageSize, _offset: page * pageSize });
      if (error) throw new Error(error.message ?? "Could not read the members");
      return parseBroadcastRecipients(data);
    },
    enabled: id !== null,
    placeholderData: keepPreviousData,
    staleTime: 15_000,
  });
}

/** "How many would really get it" — the push centre's audiences, only members who can receive messages, never the sender. */
export function useBroadcastAudience(a: PushAudience) {
  return useQuery({
    queryKey: queryKeys.adminBroadcastAudience(JSON.stringify(a)),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_broadcast_audience", { _audience: a });
      if (error) throw new Error(error.message ?? "Could not count the audience");
      const o = obj(data) ?? {};
      return { matched: num(o.matched) ?? 0, will_receive: num(o.will_receive) ?? 0, left_out: num(o.left_out) ?? 0 };
    },
    enabled: a.kind !== "members" || a.ids.length > 0,
    staleTime: 20_000,
  });
}

export function useRefreshBroadcasts() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ predicate: (q) => typeof q.queryKey[0] === "string" && (q.queryKey[0] as string).startsWith("admin-broadcast") });
}

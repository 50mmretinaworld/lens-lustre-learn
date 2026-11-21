/**
 * M8b · Admin → Messages — data. Every call is an admin-only SECURITY DEFINER rpc
 * (20261118_1300 / 1400 / 1800 / 2000); each checks has_role(admin) and, for any
 * change or any read of message text, a reason (1–500 characters) itself — the
 * page only collects them. Reading text goes through admin_read_conversation,
 * which writes the log row BEFORE it returns a single message.
 */
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { queryKeys } from "@/lib/queryKeys";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export type MessageMode = "allowed_all" | "allowed_selected" | "blocked_all" | "blocked_selected";
export const MODES: MessageMode[] = ["allowed_selected", "allowed_all", "blocked_selected", "blocked_all"];

export interface ListedMember { user_id: string; full_name: string | null; username: string | null; avatar_url: string | null; listed_at: string | null; note: string | null }
export interface MemberRule {
  user_id: string; full_name: string | null; text_ok: boolean; photos_ok: boolean; groups_ok: boolean; friends_only: boolean;
  daily_limit: number | null; blocked_until: string | null; reason: string | null; set_at: string | null;
}
export interface ControlLogRow { at: string; actor: string | null; area: string; user_id: string | null; old: string | null; new: string | null; reason: string }
export interface MessageAdminState { mode: MessageMode; groups_enabled: boolean; updated_at: string | null; members: ListedMember[]; rules: MemberRule[]; log: ControlLogRow[] }

export interface WordRule { id: number; category: string; pattern: string; lang: string | null; action: "block" | "help"; active: boolean; added_at: string | null }
export type ReportReasonKey = "spam" | "abuse" | "threat" | "nudity" | "other";
export interface ReportRow {
  id: number; status: "open" | "done"; reason: ReportReasonKey; note: string | null; created_at: string; conversation_id: string;
  reporter_id: string; reporter_name: string | null; reported_id: string | null; reported_name: string | null;
  reports_30d: number; handled_at: string | null; handled_note: string | null;
}
export interface WatchRow {
  user_id: string; full_name: string | null; username: string | null; avatar_url: string | null;
  reports_30d: number; open_reports: number; reporters: number; last_report_at: string | null; paused: boolean;
}

const str = (v: unknown) => (typeof v === "string" ? v : null);
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v)) ? Number(v) : null);
const obj = (v: unknown) => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

/** Shape guards: a malformed row is dropped, never the page. */
export function parseMessageAdminState(data: unknown): MessageAdminState {
  const o = obj(data) ?? {};
  const mode = MODES.includes(o.mode as MessageMode) ? (o.mode as MessageMode) : "allowed_selected";
  const members = arr(o.members).flatMap((r) => {
    const m = obj(r);
    if (!m || typeof m.user_id !== "string") return [];
    return [{ user_id: m.user_id, full_name: str(m.full_name), username: str(m.username), avatar_url: str(m.avatar_url), listed_at: str(m.listed_at), note: str(m.note) }];
  });
  const rules = arr(o.rules).flatMap((r) => {
    const m = obj(r);
    if (!m || typeof m.user_id !== "string") return [];
    return [{
      user_id: m.user_id, full_name: str(m.full_name), text_ok: m.text_ok !== false, photos_ok: m.photos_ok !== false,
      groups_ok: m.groups_ok !== false, friends_only: m.friends_only === true, daily_limit: num(m.daily_limit),
      blocked_until: str(m.blocked_until), reason: str(m.reason), set_at: str(m.set_at),
    }];
  });
  const log = arr(o.log).flatMap((r) => {
    const m = obj(r);
    if (!m || typeof m.at !== "string" || typeof m.area !== "string") return [];
    return [{ at: m.at, actor: str(m.actor), area: m.area, user_id: str(m.user_id), old: str(m.old), new: str(m.new), reason: str(m.reason) ?? "" }];
  });
  return { mode, groups_enabled: o.groups_enabled === true, updated_at: str(o.updated_at), members, rules, log };
}

export function parseWordRules(data: unknown): WordRule[] {
  return arr(data).flatMap((r) => {
    const m = obj(r);
    const id = num(m?.id);
    if (!m || id === null || typeof m.pattern !== "string" || typeof m.category !== "string") return [];
    if (m.action !== "block" && m.action !== "help") return [];
    return [{ id, category: m.category, pattern: m.pattern, lang: str(m.lang), action: m.action, active: m.active !== false, added_at: str(m.added_at) }];
  });
}

const REASONS: ReportReasonKey[] = ["spam", "abuse", "threat", "nudity", "other"];
export function parseReports(data: unknown): ReportRow[] {
  return arr(data).flatMap((r) => {
    const m = obj(r);
    const id = num(m?.id);
    if (!m || id === null || typeof m.conversation_id !== "string" || typeof m.reporter_id !== "string" || typeof m.created_at !== "string") return [];
    return [{
      id, status: m.status === "done" ? "done" : "open", reason: REASONS.includes(m.reason as ReportReasonKey) ? (m.reason as ReportReasonKey) : "other",
      note: str(m.note), created_at: m.created_at, conversation_id: m.conversation_id, reporter_id: m.reporter_id, reporter_name: str(m.reporter_name),
      reported_id: str(m.reported_id), reported_name: str(m.reported_name), reports_30d: num(m.reports_30d) ?? 0,
      handled_at: str(m.handled_at), handled_note: str(m.handled_note),
    }];
  });
}

export function parseWatchlist(data: unknown): WatchRow[] {
  return arr(data).flatMap((r) => {
    const m = obj(r);
    if (!m || typeof m.user_id !== "string") return [];
    return [{
      user_id: m.user_id, full_name: str(m.full_name), username: str(m.username), avatar_url: str(m.avatar_url),
      reports_30d: num(m.reports_30d) ?? 0, open_reports: num(m.open_reports) ?? 0, reporters: num(m.reporters) ?? 0,
      last_report_at: str(m.last_report_at), paused: m.paused === true,
    }];
  });
}

export function useMessageAdminState() {
  return useQuery({
    queryKey: queryKeys.adminMessagesState(),
    queryFn: async () => {
      const { data, error } = await rpc("message_admin_state");
      if (error) throw new Error(error.message ?? "Could not read the messages switch");
      return parseMessageAdminState(data);
    },
    staleTime: 30_000,
  });
}

export function useMessageWordRules() {
  return useQuery({
    queryKey: queryKeys.adminMessagesWords(),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_word_rules");
      if (error) throw new Error(error.message ?? "Could not read the word list");
      return parseWordRules(data);
    },
    staleTime: 30_000,
  });
}

export function useMessageReports(status: "open" | "done") {
  return useQuery({
    queryKey: queryKeys.adminMessagesReports(status),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_reports", { _status: status });
      if (error) throw new Error(error.message ?? "Could not read the reports");
      return parseReports(data);
    },
    // P10: an admin-only list of what members reported; 60 s keeps it current while the page is open.
    refetchInterval: 60_000,
    staleTime: 30_000,
  });
}

export function useMessageWatchlist() {
  return useQuery({
    queryKey: queryKeys.adminMessagesWatch(),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_watchlist");
      if (error) throw new Error(error.message ?? "Could not read the watch list");
      return parseWatchlist(data);
    },
    staleTime: 30_000,
  });
}

export type MemberFilter = "all" | "active" | "reported" | "paused" | "listed";
export type MemberSortKey = "name" | "chats" | "last" | "reports" | "joined";
export interface MsgMember {
  user_id: string; full_name: string | null; username: string | null; avatar_url: string | null; email: string | null; joined_at: string | null;
  chats: number; last_message_at: string | null; reports_30d: number; listed: boolean; paused: boolean; has_rules: boolean; is_admin: boolean;
}
export interface MemberSearchResult { total: number; counts: Record<MemberFilter, number>; rows: MsgMember[] }

export function parseMemberSearch(data: unknown): MemberSearchResult {
  const o = obj(data) ?? {};
  const c = obj(o.counts) ?? {};
  const rows = arr(o.rows).flatMap((r) => {
    const m = obj(r);
    if (!m || typeof m.user_id !== "string") return [];
    return [{
      user_id: m.user_id, full_name: str(m.full_name), username: str(m.username), avatar_url: str(m.avatar_url), email: str(m.email), joined_at: str(m.joined_at),
      chats: num(m.chats) ?? 0, last_message_at: str(m.last_message_at), reports_30d: num(m.reports_30d) ?? 0,
      listed: m.listed === true, paused: m.paused === true, has_rules: m.has_rules === true, is_admin: m.is_admin === true,
    }];
  });
  return {
    total: num(o.total) ?? rows.length,
    counts: { all: num(c.all) ?? 0, active: num(c.active) ?? 0, reported: num(c.reported) ?? 0, paused: num(c.paused) ?? 0, listed: num(c.listed) ?? 0 },
    rows,
  };
}

export function useMessageMembers(p: { q: string; filter: MemberFilter; sort: MemberSortKey; dir: "asc" | "desc"; page: number; pageSize: number }) {
  return useQuery({
    queryKey: queryKeys.adminMessagesMembers(p.q, p.filter, p.sort, p.dir, p.page, p.pageSize),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_member_search", {
        _q: p.q.trim() || null, _filter: p.filter, _sort: p.sort, _dir: p.dir, _limit: p.pageSize, _offset: p.page * p.pageSize,
      });
      if (error) throw new Error(error.message ?? "Could not read the members");
      return parseMemberSearch(data);
    },
    placeholderData: keepPreviousData,
    staleTime: 20_000,
  });
}

/** One audited admin call (change or logged read). Throws the server's own words on refusal. */
export async function adminMessageCall(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await rpc(fn, args);
  if (error) throw new Error(error.message ?? "Not done");
  return data;
}

/** After any change: the state, word list and held queue are stale. */
export function useRefreshAdminMessages() {
  const qc = useQueryClient();
  return () => Promise.all([
    qc.invalidateQueries({ queryKey: queryKeys.adminMessagesState() }),
    qc.invalidateQueries({ queryKey: queryKeys.adminMessagesWords() }),
    qc.invalidateQueries({ queryKey: ["admin-messages-reports"] }),
    qc.invalidateQueries({ queryKey: queryKeys.adminMessagesWatch() }),
  ]);
}

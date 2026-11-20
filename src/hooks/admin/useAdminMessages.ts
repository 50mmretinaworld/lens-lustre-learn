/**
 * M8b · Admin → Messages — data. Every call is an admin-only SECURITY DEFINER rpc
 * (20261118_1300 / 1400 / 1800 / 2000); each checks has_role(admin) and, for any
 * change or any read of message text, a reason (1–500 characters) itself — the
 * page only collects them. Reading text goes through admin_read_conversation,
 * which writes the log row BEFORE it returns a single message.
 */
import { useQuery, useQueryClient } from "@tanstack/react-query";
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

export interface WordRule { id: number; category: string; pattern: string; lang: string | null; action: "block" | "hold" | "help"; active: boolean; added_at: string | null }
export interface HeldRow { message_id: number; conversation_id: string; sender_id: string; sender_name: string | null; created_at: string }
export interface ChatOther { user_id: string; full_name: string | null; username: string | null }
export interface MemberChat { conversation_id: string; kind: "direct" | "group"; title: string | null; last_message_at: string | null; messages: number; others: ChatOther[] }
export interface ViewedMessage { id: number; sender_id: string; kind: "text" | "photo"; body: string; status: "sent" | "held" | "rejected"; created_at: string; photos: { path: string; width: number | null; height: number | null }[] }
export interface ViewedChat { conversation_id: string; members: { user_id: string; full_name: string | null; username: string | null; folder: string }[]; messages: ViewedMessage[] }

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
    if (m.action !== "block" && m.action !== "hold" && m.action !== "help") return [];
    return [{ id, category: m.category, pattern: m.pattern, lang: str(m.lang), action: m.action, active: m.active !== false, added_at: str(m.added_at) }];
  });
}

export function parseHeld(data: unknown): HeldRow[] {
  return arr(data).flatMap((r) => {
    const m = obj(r);
    const id = num(m?.message_id);
    if (!m || id === null || typeof m.conversation_id !== "string" || typeof m.sender_id !== "string" || typeof m.created_at !== "string") return [];
    return [{ message_id: id, conversation_id: m.conversation_id, sender_id: m.sender_id, sender_name: str(m.sender_name), created_at: m.created_at }];
  });
}

export function parseMemberChats(data: unknown): MemberChat[] {
  return arr(data).flatMap((r) => {
    const m = obj(r);
    if (!m || typeof m.conversation_id !== "string") return [];
    const others = arr(m.others).flatMap((x) => {
      const o = obj(x);
      return o && typeof o.user_id === "string" ? [{ user_id: o.user_id, full_name: str(o.full_name), username: str(o.username) }] : [];
    });
    return [{ conversation_id: m.conversation_id, kind: m.kind === "group" ? "group" : "direct", title: str(m.title), last_message_at: str(m.last_message_at), messages: num(m.messages) ?? 0, others }];
  });
}

export function parseViewedChat(data: unknown): ViewedChat | null {
  const o = obj(data);
  if (!o || typeof o.conversation_id !== "string") return null;
  const members = arr(o.members).flatMap((r) => {
    const m = obj(r);
    return m && typeof m.user_id === "string" ? [{ user_id: m.user_id, full_name: str(m.full_name), username: str(m.username), folder: str(m.folder) ?? "inbox" }] : [];
  });
  const messages = arr(o.messages).flatMap((r) => {
    const m = obj(r);
    const id = num(m?.id);
    if (!m || id === null || typeof m.sender_id !== "string" || typeof m.created_at !== "string") return [];
    const photos = arr(m.photos).flatMap((p) => {
      const x = obj(p);
      return x && typeof x.path === "string" ? [{ path: x.path, width: num(x.width), height: num(x.height) }] : [];
    });
    return [{
      id, sender_id: m.sender_id, kind: m.kind === "photo" ? "photo" : "text", body: str(m.body) ?? "",
      status: m.status === "held" || m.status === "rejected" ? m.status : "sent", created_at: m.created_at, photos,
    } as ViewedMessage];
  });
  return { conversation_id: o.conversation_id, members, messages };
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

export function useMessageHeldQueue() {
  return useQuery({
    queryKey: queryKeys.adminMessagesHeld(),
    queryFn: async () => {
      const { data, error } = await rpc("admin_message_held_queue");
      if (error) throw new Error(error.message ?? "Could not read the held messages");
      return parseHeld(data);
    },
    // P10: an admin-only review queue; 60 s keeps it current while the page is open.
    refetchInterval: 60_000,
    staleTime: 30_000,
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
    qc.invalidateQueries({ queryKey: queryKeys.adminMessagesHeld() }),
  ]);
}

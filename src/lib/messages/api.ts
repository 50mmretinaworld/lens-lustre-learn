/**
 * Messages · the ONE data layer (M8 prep). Screens never touch the message tables:
 * every read and write goes through these functions → the server functions of
 * migrations 20261118_1100 … _1700 (message_send, message_send_photo,
 * message_my_conversations, message_thread, …). The server decides everything;
 * this file only shapes the answers and names the refusals.
 *
 * Text is PLAIN TEXT only: a message body is never inserted as HTML anywhere.
 * A reply that does not have the expected shape is dropped, never half-shown.
 */
import { supabase } from "@/integrations/supabase/client";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export type MessageFolder = "inbox" | "requests";

export interface MessagePerson {
  userId: string;
  fullName: string | null;
  username: string | null;
  avatarUrl: string | null;
}
export interface ConversationSummary {
  conversationId: string;
  folder: string;
  muted: boolean;
  lastMessageAt: string | null;
  other: MessagePerson | null;
  last: { id: number; senderId: string; kind: "text" | "photo"; body: string; createdAt: string } | null;
  unread: number;
}
export interface MessagePhoto { path: string; width: number | null; height: number | null }
export interface ThreadMessage {
  id: number;
  senderId: string;
  kind: "text" | "photo";
  body: string;
  createdAt: string;
  /** Only the sender's own held message says 'held'; everything else is 'sent'. */
  status: "sent" | "held";
  photos: MessagePhoto[];
}
export interface SendResult {
  messageId: number;
  conversationId: string;
  duplicate: boolean;
  status: "sent" | "held";
  folder: string | null;
  /** The word guard found a self-harm phrase: show the helpline. */
  help: boolean;
}

/** Why a send was refused, in words the screen can map to a calm message. */
export type SendRefusal =
  | "sign_in" | "under_review" | "bad_recipient" | "bad_message" | "not_available" | "recipient_unavailable"
  | "paused" | "text_off" | "photos_off" | "friends_only" | "blocked" | "no_link"
  | "too_fast" | "daily_limit" | "chat_limit" | "photo_limit" | "word_guard" | "bad_photo" | "unknown";

const REFUSALS: Record<string, SendRefusal> = {
  "MSG-001": "sign_in", ACCOUNT_UNDER_REVIEW: "under_review", "MSG-002": "bad_recipient", "MSG-003": "bad_message",
  "MSG-010": "not_available", "MSG-011": "recipient_unavailable", "MSG-020": "paused", "MSG-021": "text_off",
  "MSG-022": "friends_only", "MSG-023": "photos_off", "MSG-024": "bad_photo", "MSG-025": "bad_photo",
  "MSG-030": "blocked", "MSG-040": "no_link", "MSG-050": "too_fast", "MSG-051": "daily_limit",
  "MSG-052": "chat_limit", "MSG-053": "photo_limit", "MSG-060": "word_guard",
};

export class MessageSendError extends Error {
  constructor(public refusal: SendRefusal, message: string) {
    super(message);
    this.name = "MessageSendError";
  }
}

/** The server's refusal code is the first token of its error text (e.g. "MSG-040: …"). */
export function refusalFrom(message: string | undefined | null): SendRefusal {
  const m = /(ACCOUNT_UNDER_REVIEW|MSG-\d{3})/.exec(message ?? "");
  return (m && REFUSALS[m[1]]) || "unknown";
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

function person(v: unknown): MessagePerson | null {
  if (!isObj(v) || !str(v.user_id)) return null;
  return { userId: v.user_id as string, fullName: str(v.full_name), username: str(v.username), avatarUrl: str(v.avatar_url) };
}

export function parseConversations(data: unknown): ConversationSummary[] {
  if (!Array.isArray(data)) return [];
  const out: ConversationSummary[] = [];
  for (const r of data) {
    if (!isObj(r) || !str(r.conversation_id)) continue;
    const last = isObj(r.last) && num(r.last.id) !== null && str(r.last.sender_id) && str(r.last.created_at)
      ? { id: r.last.id as number, senderId: r.last.sender_id as string, kind: (r.last.kind === "photo" ? "photo" : "text") as "text" | "photo",
          body: str(r.last.body) ?? "", createdAt: r.last.created_at as string }
      : null;
    out.push({
      conversationId: r.conversation_id as string, folder: str(r.folder) ?? "inbox", muted: r.muted === true,
      lastMessageAt: str(r.last_message_at), other: person(r.other), last, unread: num(r.unread) ?? 0,
    });
  }
  return out;
}

export function parseThread(data: unknown): ThreadMessage[] {
  if (!Array.isArray(data)) return [];
  const out: ThreadMessage[] = [];
  for (const r of data) {
    if (!isObj(r) || num(r.id) === null || !str(r.sender_id) || !str(r.created_at)) continue;
    const photos: MessagePhoto[] = Array.isArray(r.photos)
      ? r.photos.filter(isObj).filter((p) => !!str(p.path)).map((p) => ({ path: p.path as string, width: num(p.width), height: num(p.height) }))
      : [];
    out.push({
      id: r.id as number, senderId: r.sender_id as string, kind: r.kind === "photo" ? "photo" : "text",
      body: str(r.body) ?? "", createdAt: r.created_at as string, status: r.status === "held" ? "held" : "sent", photos,
    });
  }
  return out;
}

export function parseUnread(data: unknown): { inbox: number; requests: number } {
  const o = isObj(data) ? data : {};
  return { inbox: num(o.inbox) ?? 0, requests: num(o.requests) ?? 0 };
}

export function parseSendResult(data: unknown): SendResult | null {
  if (!isObj(data) || num(data.message_id) === null || !str(data.conversation_id)) return null;
  return {
    messageId: data.message_id as number, conversationId: data.conversation_id as string, duplicate: data.duplicate === true,
    status: data.status === "held" ? "held" : "sent", folder: str(data.folder), help: data.help === true,
  };
}

/** One id per user action: a retry of the same action reuses it, so the server never stores it twice. */
export const newClientMsgId = (): string => crypto.randomUUID();

export async function fetchConversations(folder: MessageFolder, limit = 30, before: string | null = null): Promise<ConversationSummary[]> {
  const { data, error } = await rpc("message_my_conversations", { _folder: folder, _limit: limit, _before: before });
  if (error) throw new Error(error.message ?? "message_my_conversations failed");
  return parseConversations(data);
}
export async function fetchThread(conversationId: string, beforeId: number | null = null, limit = 50): Promise<ThreadMessage[]> {
  const { data, error } = await rpc("message_thread", { _conversation: conversationId, _before_id: beforeId, _limit: limit });
  if (error) throw new Error(error.message ?? "message_thread failed");
  return parseThread(data);
}
export async function fetchUnread(): Promise<{ inbox: number; requests: number }> {
  const { data, error } = await rpc("message_unread_counts");
  if (error) return { inbox: 0, requests: 0 };
  return parseUnread(data);
}
/** Whether the Message button should show. The server refuses a send anyway. */
export async function fetchMessagingAllowed(): Promise<boolean> {
  const { data, error } = await rpc("message_allowed_me");
  return !error && data === true;
}

export async function sendMessage(to: string, body: string, clientMsgId: string): Promise<SendResult> {
  const { data, error } = await rpc("message_send", { _to: to, _body: body, _client_msg_id: clientMsgId });
  if (error) throw new MessageSendError(refusalFrom(error.message), error.message ?? "send refused");
  const r = parseSendResult(data);
  if (!r) throw new MessageSendError("unknown", "unexpected reply");
  return r;
}
export async function sendPhotos(
  to: string, caption: string, clientMsgId: string, photos: Array<{ path: string; width?: number; height?: number }>,
): Promise<SendResult> {
  const { data, error } = await rpc("message_send_photo", { _to: to, _caption: caption, _client_msg_id: clientMsgId, _photos: photos });
  if (error) throw new MessageSendError(refusalFrom(error.message), error.message ?? "send refused");
  const r = parseSendResult(data);
  if (!r) throw new MessageSendError("unknown", "unexpected reply");
  return r;
}

export async function markConversationRead(conversationId: string): Promise<void> {
  await rpc("message_mark_read", { _conversation: conversationId });
}
export async function acceptRequest(conversationId: string): Promise<void> {
  const { error } = await rpc("message_accept_request", { _conversation: conversationId });
  if (error) throw new Error(error.message ?? "accept failed");
}
export async function declineRequest(conversationId: string): Promise<void> {
  const { error } = await rpc("message_decline_request", { _conversation: conversationId });
  if (error) throw new Error(error.message ?? "decline failed");
}
export async function setConversationMuted(conversationId: string, muted: boolean): Promise<void> {
  const { error } = await rpc("message_set_muted", { _conversation: conversationId, _muted: muted });
  if (error) throw new Error(error.message ?? "mute failed");
}

/** A 5-minute link for one photo; storage creates it only if the server's read rule passes. */
export async function signedPhotoUrl(path: string): Promise<string | null> {
  const { data, error } = await supabase.storage.from("message-photos").createSignedUrl(path, 300);
  return error || !data ? null : data.signedUrl;
}

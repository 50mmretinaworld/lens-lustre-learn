/**
 * Messages · group chats (SQL 1900 doors + 3700 reads). Kept apart from api.ts: groups are OFF until an admin switches them on,
 * so none of this loads unless a member opens a group or the "New group" button is shown.
 * The server decides everything (switch, friends only, chat facility, limits); the screens only ask and show.
 */
import { supabase } from "@/integrations/supabase/client";
import { MessageSendError, parseSendResult, refusalFrom, type MessagePerson, type SendResult } from "@/lib/messages/api";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export interface GroupMember extends MessagePerson { role: "owner" | "member" }

function isObj(v: unknown): v is Record<string, unknown> { return typeof v === "object" && v !== null; }
function str(v: unknown): string | null { return typeof v === "string" && v !== "" ? v : null; }
function personOf(r: Record<string, unknown>): MessagePerson | null {
  const id = str(r.user_id);
  return id ? { userId: id, fullName: str(r.full_name), username: str(r.username), avatarUrl: str(r.avatar_url) } : null;
}

export function parseGroupMembers(data: unknown): GroupMember[] {
  if (!Array.isArray(data)) return [];
  return data.filter(isObj).flatMap((r) => { const p = personOf(r); return p ? [{ ...p, role: r.role === "owner" ? "owner" as const : "member" as const }] : []; });
}
export function parseGroupFriends(data: unknown): MessagePerson[] {
  if (!Array.isArray(data)) return [];
  return data.filter(isObj).flatMap((r) => { const p = personOf(r); return p ? [p] : []; });
}

/** May this member use groups at all (switch on + chat facility + own rule)? Shows the "New group" button. */
export async function fetchGroupsAllowed(): Promise<boolean> {
  const { data, error } = await rpc("message_groups_allowed_me");
  return !error && data === true;
}
export async function fetchGroupFriends(): Promise<MessagePerson[]> {
  const { data, error } = await rpc("message_group_friends");
  if (error) throw new Error(error.message ?? "could not load your friends");
  return parseGroupFriends(data);
}
export async function fetchGroupMembers(conversationId: string): Promise<GroupMember[]> {
  const { data, error } = await rpc("message_group_members", { _conversation: conversationId });
  if (error) throw new Error(error.message ?? "could not load the members");
  return parseGroupMembers(data);
}
export async function createGroup(title: string, memberIds: string[]): Promise<string> {
  const { data, error } = await rpc("message_group_create", { _title: title, _members: memberIds });
  if (error) throw new MessageSendError(refusalFrom(error.message), error.message ?? "could not create the group");
  if (typeof data !== "string") throw new MessageSendError("unknown", "unexpected reply");
  return data;
}
export async function groupAddMember(conversationId: string, userId: string): Promise<void> {
  const { error } = await rpc("message_group_add", { _conversation: conversationId, _user: userId });
  if (error) throw new MessageSendError(refusalFrom(error.message), error.message ?? "could not add");
}
export async function groupRemoveMember(conversationId: string, userId: string): Promise<void> {
  const { error } = await rpc("message_group_remove", { _conversation: conversationId, _user: userId });
  if (error) throw new MessageSendError(refusalFrom(error.message), error.message ?? "could not remove");
}
export async function groupLeave(conversationId: string): Promise<void> {
  const { error } = await rpc("message_group_leave", { _conversation: conversationId });
  if (error) throw new MessageSendError(refusalFrom(error.message), error.message ?? "could not leave");
}
export async function sendGroupMessage(conversationId: string, body: string, clientMsgId: string): Promise<SendResult> {
  const { data, error } = await rpc("message_send_group", { _conversation: conversationId, _body: body, _client_msg_id: clientMsgId });
  if (error) throw new MessageSendError(refusalFrom(error.message), error.message ?? "send refused");
  const r = parseSendResult(data);
  if (!r) throw new MessageSendError("unknown", "unexpected reply");
  return r;
}

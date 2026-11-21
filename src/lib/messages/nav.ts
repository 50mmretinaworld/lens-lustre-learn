/**
 * Messages · the ONE read the top bar needs on every page: is the Message button allowed for this member?
 * Kept apart from api.ts on purpose: the top bar is in the first download, and the rest of the messages code
 * (parsers, send, photos, unread count) loads only when someone opens a chat. The server decides.
 */
import { supabase } from "@/integrations/supabase/client";

export async function fetchMessagingAllowed(): Promise<boolean> {
  const { data, error } = await (supabase.rpc as unknown as (fn: string) => Promise<{ data: unknown; error: unknown }>)("message_allowed_me");
  return !error && data === true;
}

/** May the caller start a chat with THIS member? Yes only when that member has the chat facility too (the server decides). */
export async function fetchCanReachMember(userId: string): Promise<boolean> {
  const { data, error } = await (supabase.rpc as unknown as (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>)("message_can_reach", { _user: userId });
  return !error && data === true;
}

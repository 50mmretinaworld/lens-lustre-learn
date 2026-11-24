/**
 * Messages · the ONE read the top bar needs on every page: is the Message button allowed for this member?
 * Kept apart from api.ts on purpose: the top bar is in the first download, and the rest of the messages code
 * (parsers, send, photos, unread count) loads only when someone opens a chat. The server decides.
 *
 * A failed read (timeout, poor network) THROWS — it is "unknown", never "no". Owner 23 Nov: on a poor network
 * the footer Chat icon went out and came back, because every failed re-check was read as "not allowed".
 * React Query keeps the last real answer when a fetch throws.
 */
import { supabase } from "@/integrations/supabase/client";
import { startPart } from "@/lib/appStart";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;

async function askBool(fn: string, args?: Record<string, unknown>): Promise<boolean> {
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, args);
  if (error) throw error;
  return data === true;
}

export const fetchMessagingAllowed = async (): Promise<boolean> => {
  // N6-1: at app start the one start-up answer carries it (same function, same rule).
  const pre = await startPart<boolean>("message_allowed");
  if (typeof pre === "boolean") return pre;
  return askBool("message_allowed_me");
};

/** May the caller start a chat with THIS member? Yes only when that member has the chat facility too (the server decides). */
export const fetchCanReachMember = (userId: string): Promise<boolean> => askBool("message_can_reach", { _user: userId });

/** The last answer this device got, per member — so the icon is in place on the first frame (null = never asked). */
const KEY = "msg-allowed:";
export function rememberedAllowed(userId: string): boolean | undefined {
  try {
    const v = localStorage.getItem(KEY + userId);
    return v === "1" ? true : v === "0" ? false : undefined;
  } catch {
    return undefined;
  }
}
export function rememberAllowed(userId: string, allowed: boolean): void {
  try { localStorage.setItem(KEY + userId, allowed ? "1" : "0"); } catch { /* storage off: no memory, still correct */ }
}

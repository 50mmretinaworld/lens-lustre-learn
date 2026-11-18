/**
 * Messages · the two tiny reads the top bar needs on EVERY page (is the Message button allowed? how many unread?).
 * Kept apart from api.ts on purpose: the top bar is in the first download, and the rest of the messages code
 * (parsers, send, photos) loads only when someone opens a chat. The server decides; these only ask.
 */
import { supabase } from "@/integrations/supabase/client";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export async function fetchMessagingAllowed(): Promise<boolean> {
  const { data, error } = await rpc("message_allowed_me");
  return !error && data === true;
}

export async function fetchUnread(): Promise<{ inbox: number; requests: number }> {
  const { data, error } = await rpc("message_unread_counts");
  if (error || typeof data !== "object" || data === null) return { inbox: 0, requests: 0 };
  const o = data as Record<string, unknown>;
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  return { inbox: n(o.inbox), requests: n(o.requests) };
}

/** Messages · the unread count (inbox + requests) for the badge. Loaded only with the messages UI, not the first download. */
import { supabase } from "@/integrations/supabase/client";

export async function fetchUnread(): Promise<{ inbox: number; requests: number }> {
  const { data, error } = await (supabase.rpc as unknown as (fn: string) => Promise<{ data: unknown; error: unknown }>)("message_unread_counts");
  if (error || typeof data !== "object" || data === null) return { inbox: 0, requests: 0 };
  const o = data as Record<string, unknown>;
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  const counts = { inbox: n(o.inbox), requests: n(o.requests) };
  // This app has just heard about those messages: tell the senders they are delivered (double grey tick).
  // Only when something is waiting, so a quiet inbox costs nothing. Fire-and-forget.
  if (counts.inbox + counts.requests > 0) {
    void (supabase.rpc as unknown as (fn: string) => Promise<unknown>)("message_mark_delivered").then(undefined, () => undefined);
  }
  return counts;
}

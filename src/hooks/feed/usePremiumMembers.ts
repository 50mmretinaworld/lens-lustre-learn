/**
 * PREMIUM MEMBERS — the ONE reader (Owner-approved plan, 26 Nov 2026).
 *
 * The feed row ("Meet our Premium Members") and the /premium-members page read
 * the same query, so a member honoured or un-honoured shows the same in both.
 * The database decides everything (20261126_6000 get_premium_members): who is
 * honoured, the photo (Featured, else most-liked public photo), the line
 * (curator's citation, else first line of bio, else none), the honour date.
 * Callable signed out.
 *
 * DEGRADES TO NOTHING: if the function is not on this database yet, or the
 * call fails, the answer is an empty list — the row and the grid simply do not
 * render. No error toast, no retry storm.
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/core/useAuth";

export interface PremiumMember {
  user_id: string;
  full_name: string;
  handle: string | null;
  avatar_url: string | null;
  post_id: string | null;
  photo_url: string | null;
  thumb_url: string | null;
  is_featured: boolean;
  line: string | null;
  line_is_citation: boolean;
  honoured_at: string | null;
}

export const PREMIUM_MEMBERS_KEY = ["premium-members"] as const;
export const PREMIUM_MEMBERS_LIMIT = 60;

const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v : null);

/** Parsed defensively: a row without an id is dropped; every other field has a safe default. */
export function parsePremiumMembers(raw: unknown): PremiumMember[] {
  if (!Array.isArray(raw)) return [];
  const out: PremiumMember[] = [];
  for (const r of raw as Record<string, unknown>[]) {
    if (!r || typeof r.user_id !== "string" || !r.user_id) continue;
    out.push({
      user_id: r.user_id,
      full_name: str(r.full_name) ?? "Member",
      handle: str(r.handle),
      avatar_url: str(r.avatar_url),
      post_id: str(r.post_id),
      photo_url: str(r.photo_url),
      thumb_url: str(r.thumb_url),
      is_featured: r.is_featured === true,
      line: str(r.line),
      line_is_citation: r.line_is_citation === true,
      honoured_at: str(r.honoured_at),
    });
  }
  return out;
}

export function usePremiumMembers(enabled = true) {
  return useQuery({
    queryKey: PREMIUM_MEMBERS_KEY,
    enabled,
    staleTime: 5 * 60_000,
    retry: false,
    queryFn: async (): Promise<PremiumMember[]> => {
      try {
        const { data, error } = await supabase.rpc("get_premium_members" as never, { _limit: PREMIUM_MEMBERS_LIMIT } as never);
        if (error) return [];
        return parsePremiumMembers(data);
      } catch {
        return [];
      }
    },
  });
}

/**
 * Which of these members the signed-in viewer already follows — ONE read for
 * the whole list (never one per card), bounded by the list itself (≤ 60).
 * Key starts with "follows", so useToggleFollow's invalidation refreshes it.
 */
export function usePremiumFollowing(ids: readonly string[]) {
  const { user } = useAuth();
  const me = user?.id ?? null;
  return useQuery({
    queryKey: ["follows", "premium", me, ids.join(",")] as const,
    enabled: !!me && ids.length > 0,
    staleTime: 60_000,
    queryFn: async (): Promise<Set<string>> => {
      const { data, error } = await supabase
        .from("follows")
        .select("following_id")
        .eq("follower_id", me!)
        .in("following_id", [...ids])
        .limit(ids.length);
      if (error) return new Set();
      return new Set((data ?? []).map((r: { following_id: string }) => r.following_id));
    },
  });
}

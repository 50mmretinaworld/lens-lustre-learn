/**
 * N6-2 · ONE REQUEST FOR A FEED PAGE'S EXTRAS (Owner 24 Nov 2026: "go on" — close the gap to Meta).
 *
 * Measured (UI harness, real app code): after get_feed_page every page sent ~12 more reads in 3–4 waves — names
 * (then badges + roles), reactions, friendships, view counts, tags, then the TAGGED people's names (a second wave),
 * photos, videos, contributor scores and old-photo credits. Each is ~0.2 s of travel from India.
 * `get_feed_extras` (SQL 20261124_5300, SECURITY INVOKER — the member's own rights) answers all of them in ONE
 * round trip.
 *
 * The rule is the same as N6-1's start-up answer: every part is OPTIONAL. A part that is missing (signed out, a lane
 * without the function, a part that failed inside it, a slow or failed request) is simply absent from the result,
 * and the feed asks for that part alone, exactly as before. So the worst case is today's behaviour.
 *
 * A lane without the function (the server says "function not found") is remembered for this page load, so it costs
 * at most ONE wasted request, never one per page.
 */
import { supabase } from "@/integrations/supabase/client";
import { getLogUser } from "@/lib/logger";
import { isNativeCapacitorApp } from "@/lib/native/authDeepLink";

type Rows = Record<string, unknown>[];

export interface FeedExtras {
  /** Every id the names below answer for (authors + tagged people) — also the ones with no row. */
  profile_ids?: string[];
  profiles?: Rows;
  badges?: Rows;
  roles?: Rows;
  reactions?: Rows;
  friendships?: Rows;
  view_counts?: Rows;
  tags?: Rows;
  media?: Rows;
  videos?: Rows;
  scores?: Rows;
  credits?: Rows;
}

/** The same cap every separate read already has (post_media_for, post_videos, credits). */
export const FEED_EXTRAS_MAX_IDS = 50;
const WAIT_MS = 8_000;

let missingOnLane = false;

function withTimeout<T>(p: PromiseLike<T>, ms: number, fallback: T): Promise<T> {
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(fallback), ms);
    Promise.resolve(p).then((v) => { clearTimeout(t); resolve(v); }, () => { clearTimeout(t); resolve(fallback); });
  });
}

function isFunctionMissing(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null;
  return e?.code === "PGRST202" || e?.code === "42883" || /could not find the function/i.test(e?.message ?? "");
}

/**
 * The extras for one feed page. Never throws; `{}` = ask every part alone. Only for the signed-in member (`uid`).
 */
export async function fetchFeedExtras(postIds: string[], authorIds: string[], uid: string): Promise<FeedExtras> {
  if (missingOnLane || !uid || getLogUser() !== uid) return {};
  const posts = [...new Set(postIds)].filter(Boolean);
  const authors = [...new Set(authorIds)].filter(Boolean);
  if (posts.length === 0 || posts.length > FEED_EXTRAS_MAX_IDS || authors.length > FEED_EXTRAS_MAX_IDS) return {};
  try {
    const res = await withTimeout(
      (supabase.rpc as unknown as (fn: string, a: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>)(
        "get_feed_extras",
        // credits are only ever read on the web (the app has no save), so the app does not ask the server for them
        { _post_ids: posts, _author_ids: authors, _credits: !isNativeCapacitorApp() },
      ),
      WAIT_MS,
      { data: null, error: { message: "timeout" } },
    );
    if (res.error) {
      if (isFunctionMissing(res.error)) missingOnLane = true;
      return {};
    }
    const d = res.data;
    if (!d || typeof d !== "object" || Array.isArray(d)) return {};
    const out: FeedExtras = {};
    for (const [k, v] of Object.entries(d as Record<string, unknown>)) {
      if (Array.isArray(v)) (out as Record<string, unknown>)[k] = v;
    }
    return out;
  } catch {
    return {};
  }
}

/** A finished `{ data, error }` for a part the one answer already holds, so the feed's code reads it unchanged. */
export function answered<T>(rows: T): Promise<{ data: T; error: null }> {
  return Promise.resolve({ data: rows, error: null });
}

/** Tests only. */
export function resetFeedExtrasForTests(): void {
  missingOnLane = false;
}

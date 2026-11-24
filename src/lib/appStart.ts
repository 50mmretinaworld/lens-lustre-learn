/**
 * N6-1 · ONE START-UP REQUEST (Owner 24 Nov 2026: "go on" — close the gap to Meta).
 *
 * Measured (UI harness, real app code): every signed-in screen sent ~15 separate start-up reads, each ~0.2 s of
 * travel from India. `get_app_start` (SQL 20261124_5200, SECURITY INVOKER — the member's own rights) answers them
 * in ONE round trip. Each reader below asks `startPart(...)` first:
 *
 *   - the FIRST reader to ask sends the one request; every other reader waits for that same answer;
 *   - a part is handed out ONCE per page load (the app start). Every later refresh — the bell's minute poll, the
 *     switches' 60 s check, a manual refresh — goes to the network exactly as before;
 *   - anything missing (signed out, a lane without the function, a part that failed inside it, a slow or failed
 *     request, an answer older than 30 s) returns `undefined`, and the reader asks alone, as before.
 *
 * So the worst case is today's behaviour; the normal case is one request instead of ~15.
 */
import { supabase } from "@/integrations/supabase/client";
import { getLogUser } from "@/lib/logger";

export type StartPart =
  | "features" | "message_allowed" | "account_state" | "admin_ids" | "me" | "blocked" | "categories"
  | "trending" | "stories_bar" | "my_stories" | "drafts" | "bell" | "gift_unread" | "my_profile";

/** The bell's own constants, sent with the request so the start-up answer is the same read the bell makes. */
export const START_BELL_LIMIT = 20;
export const START_BELL_EXCLUDE = ["friend_request"];

const MAX_AGE_MS = 30_000;
const WAIT_MS = 6_000;

type Answer = Record<string, unknown> | null;
let current: { uid: string; at: number; answer: Promise<Answer>; used: Set<string> } | null = null;
const startedFor = new Set<string>();

async function ask(): Promise<Answer> {
  try {
    const { data, error } = await (supabase.rpc as unknown as (
      fn: string, args: Record<string, unknown>,
    ) => PromiseLike<{ data: unknown; error: unknown }>)("get_app_start", {
      _bell_limit: START_BELL_LIMIT,
      _bell_exclude: START_BELL_EXCLUDE,
    });
    if (error || !data || typeof data !== "object" || Array.isArray(data)) return null;
    return data as Record<string, unknown>;
  } catch {
    return null;
  }
}

function withTimeout<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(fallback), ms);
    p.then((v) => { clearTimeout(t); resolve(v); }, () => { clearTimeout(t); resolve(fallback); });
  });
}

/**
 * The start-up answer for `part`, for member `uid` (defaults to the signed-in member the auth hook reported).
 * `undefined` = ask alone. A part's value may legitimately be `null` (e.g. "me" when the member has no row).
 * `reader` names who takes it when one part serves two readers ("me": the banned flag and the online-dot privacy):
 * each reader gets it once.
 */
/**
 * N6-3: the member whose session is SAVED on this device (supabase-js keeps it as `sb-<project>-auth-token`). Readers
 * that run before the auth hook has reported the member (measured: the admin list on Notifications and the wall)
 * used to miss the start-up answer and ask alone. The request itself is sent with that same session, so the answer
 * is that member's. null when nothing is saved or it cannot be read.
 */
function savedSessionUser(): string | null {
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i) ?? "";
      if (!/^sb-.+-auth-token$/.test(k)) continue;
      const id = (JSON.parse(localStorage.getItem(k) ?? "null") as { user?: { id?: unknown } } | null)?.user?.id;
      if (typeof id === "string" && id) return id;
    }
  } catch { /* unreadable storage: wait for the auth hook, as before */ }
  return null;
}

export async function startPart<T = unknown>(part: StartPart, uid?: string | null, reader = ""): Promise<T | undefined> {
  const me = getLogUser() ?? savedSessionUser();
  // Only ever for the signed-in member: a reader asking about SOMEONE ELSE never gets the start-up answer.
  if (uid && me && uid !== me) return undefined;
  const who = uid ?? me;
  if (!who) return undefined;
  if (!current || current.uid !== who) {
    if (startedFor.has(who)) return undefined;   // one start per member per page load
    startedFor.add(who);
    current = { uid: who, at: Date.now(), answer: ask(), used: new Set() };
  }
  const run = current;
  const slot = `${part}:${reader}`;
  if (run.used.has(slot) || Date.now() - run.at > MAX_AGE_MS) return undefined;
  const answer = await withTimeout(run.answer, WAIT_MS, null);
  if (!answer || !Object.prototype.hasOwnProperty.call(answer, part)) return undefined;
  if (run.used.has(slot) || Date.now() - run.at > MAX_AGE_MS) return undefined;
  run.used.add(slot);
  return answer[part] as T;
}

/** Tests only. */
export function resetAppStartForTests(): void {
  current = null;
  startedFor.clear();
}

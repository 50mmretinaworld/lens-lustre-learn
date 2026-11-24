/**
 * N6-4 · LOAD THE NEXT SCREEN BEFORE THE TAP (Owner 24 Nov 2026: "go on" — close the gap to Meta).
 *
 * A tap takes ~100 ms from finger-down to the click (a mouse hover, several hundred). Every main screen is a lazy
 * chunk, and its first data is a server read of ~0.2 s from India — so the screen used to start loading only AFTER
 * the tap. Now, the moment a finger touches (or a mouse rests on, or the keyboard focuses) a link or a button marked
 * `data-prefetch="/path"`, that screen's code starts downloading, and for the two busiest member screens its first
 * data too (Messages: the chat list; Notifications: the first page) — into the SAME React Query entries the screens
 * read, so they open from it.
 *
 * Once the app is idle on a good connection, the main tabs' code is fetched quietly too (code only, never data).
 * Nothing is fetched on a slow connection or with Data Saver (getNetState().slow), and each screen at most once per
 * page load. Every failure is silent: the screen then loads exactly as before.
 */
import type { QueryClient } from "@tanstack/react-query";
import { getLogUser } from "@/lib/logger";
import { getNetState } from "@/lib/offline/networkQuality";

let qc: QueryClient | null = null;
export function setPrefetchQueryClient(c: QueryClient): void { qc = c; }

type Target = {
  key: string;
  chunk: () => Promise<unknown>;
  /** First data for a signed-in member, into the screen's own query entry. */
  data?: (c: QueryClient, uid: string) => Promise<unknown>;
};

const TARGETS: Array<[RegExp, Target]> = [
  [/^\/messages(\/|$)/, {
    key: "messages",
    chunk: () => import("@/pages/MessagesRoutes"),
    data: async (c, uid) => {
      const [{ fetchConversations }, { messageKeys }] = await Promise.all([import("@/lib/messages/api"), import("@/lib/messages/keys")]);
      await c.prefetchQuery({ queryKey: messageKeys.conversations(uid, "inbox"), queryFn: () => fetchConversations("inbox", 30), staleTime: 10_000 });
    },
  }],
  [/^\/notifications\/?$/, {
    key: "notifications",
    chunk: () => import("@/pages/Notifications"),
    data: async (c, uid) => {
      const { fetchNotificationPage } = await import("@/hooks/notifications/useNotificationHistory");
      await c.prefetchInfiniteQuery({
        queryKey: ["notification-history", uid],
        initialPageParam: null as string | null,
        queryFn: ({ pageParam }) => fetchNotificationPage(pageParam as string | null),
        staleTime: 30_000,
      });
    },
  }],
  [/^\/(home)?\/?$/, { key: "home", chunk: () => import("@/pages/Index") }],
  [/^\/feed\/?$/, { key: "feed", chunk: () => import("@/pages/Feed") }],
  [/^\/competitions\/?$/, { key: "competitions", chunk: () => import("@/pages/Competitions") }],
  [/^\/journal\/?$/, { key: "journal", chunk: () => import("@/pages/Journal") }],
  [/^\/courses\/?$/, { key: "courses", chunk: () => import("@/pages/Courses") }],
  [/^\/winners\/?$/, { key: "winners", chunk: () => import("@/pages/Winners") }],
  [/^\/discover\/?$/, { key: "discover", chunk: () => import("@/pages/Discover") }],
];

const doneChunk = new Set<string>();
const doneData = new Set<string>();

function targetFor(path: string): Target | null {
  for (const [re, t] of TARGETS) if (re.test(path)) return t;
  return null;
}

/** Start loading the screen at `path` (code; data too when `withData` and signed in). Never throws. */
export function prefetchPath(path: string, withData = true): void {
  try {
    if (getNetState().slow) return;
    const t = targetFor(path);
    if (!t) return;
    if (!doneChunk.has(t.key)) {
      doneChunk.add(t.key);
      void t.chunk().catch(() => { doneChunk.delete(t.key); });
    }
    const uid = getLogUser();
    if (withData && t.data && qc && uid && !doneData.has(`${uid}:${t.key}`)) {
      doneData.add(`${uid}:${t.key}`);
      void t.data(qc, uid).catch(() => { doneData.delete(`${uid}:${t.key}`); });
    }
  } catch { /* the screen simply loads as before */ }
}

function pathOf(el: Element | null): string | null {
  const marked = el?.closest?.("[data-prefetch]");
  if (marked) return marked.getAttribute("data-prefetch");
  const a = el?.closest?.("a[href]") as HTMLAnchorElement | null;
  if (!a) return null;
  try {
    const u = new URL(a.href, window.location.href);
    return u.origin === window.location.origin ? u.pathname : null;
  } catch { return null; }
}

let installed = false;
/** One listener for the whole app (App.tsx). Safe to call more than once. */
export function installPrefetchNext(): void {
  if (installed || typeof document === "undefined") return;
  installed = true;
  const onIntent = (e: Event) => {
    const p = pathOf(e.target as Element | null);
    if (p) prefetchPath(p);
  };
  for (const type of ["touchstart", "pointerdown", "mouseover", "focusin"]) {
    document.addEventListener(type, onIntent, { capture: true, passive: true });
  }
  // The main tabs' code, once the app is idle on a good connection (no data).
  const idle = (fn: () => void) => {
    const ric = (window as unknown as { requestIdleCallback?: (f: () => void, o?: { timeout: number }) => void }).requestIdleCallback;
    if (ric) ric(fn, { timeout: 8_000 }); else setTimeout(fn, 4_000);
  };
  setTimeout(() => idle(() => {
    for (const p of ["/", "/competitions", "/notifications", "/messages"]) prefetchPath(p, false);
  }), 5_000);
}

/** Tests only. */
export function resetPrefetchForTests(): void {
  doneChunk.clear(); doneData.clear(); installed = false; qc = null;
}

/**
 * PUSH CENTRE · where a tapped admin push may open.
 *
 * Two uses, one rule:
 *   · the admin page warns when an address opens the dashboard on apps that
 *     members have today (builds ≤ 1.2.49 ignore the address — Owner bug
 *     16 Nov 2026, "/competitions does not open there");
 *   · the app (from 1.2.50) opens `link` from the push only when it is an
 *     address inside this site.
 *
 * Two copies of the rule, kept identical by src/__tests__/broadcastTapMirror.test.ts:
 *   src/lib/notifications/broadcastTap.ts              — this file (the site and the app)
 *   supabase/functions/_shared/broadcastMessage.ts    — the sender (safeLink,
 *                                                       legacyTapTarget, LEGACY_TAP_PAGES)
 * Plain TypeScript only (no imports), so both runtimes load it.
 */

const SAFE_LINK = /^\/([A-Za-z0-9_-][A-Za-z0-9/_.?=&%#-]*)?$/;

/** An address inside this site ("/…"), or null. Never a full URL, never "//host". */
export function safeAppLink(link: unknown): string | null {
  return typeof link === "string" && link.length <= 300 && SAFE_LINK.test(link) ? link : null;
}

/** First path parts a tap opens on EVERY app build. */
export const TAP_PAGES_EVERY_APP = [
  "/", "/feed", "/post", "/competitions", "/journal", "/courses", "/friends", "/certificates", "/discover",
  "/help-support", "/wallet", "/dashboard",
] as const;

/** Pages that also open one item: "/competitions/<name>". */
const WITH_ITEM = new Set(["competitions", "journal", "courses"]);

/** True when a tap opens this address on every app build; false = dashboard on builds ≤ 1.2.49. */
export function opensOnEveryApp(link: string): boolean {
  const safe = safeAppLink(link);
  if (!safe) return false;
  const seg = safe.split(/[?#]/)[0].split("/").filter(Boolean);
  if (seg.length === 0) return true;
  if (!(TAP_PAGES_EVERY_APP as readonly string[]).includes(`/${seg[0]}`)) return false;
  if (seg[0] === "post") return seg.length === 2;
  if (WITH_ITEM.has(seg[0])) return seg.length <= 2;
  return seg.length === 1;
}

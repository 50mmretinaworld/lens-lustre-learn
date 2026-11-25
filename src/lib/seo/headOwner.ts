/**
 * ONE HEAD, ONE OWNER (Search Console 25 Nov 2026). Measured live on a post page after its JavaScript ran:
 * 3 descriptions, 3 robots, 3 canonicals, and the edge's title replaced by a generic "Post by …". Cause: React 19
 * hoists every <Helmet> child into <head> and never de-duplicates (react-helmet-async 3 is a passthrough), so the
 * edge's tags + Layout's default <PageSEO/> + the page's own <PageSEO/> all stayed.
 *
 * The rule, in one place:
 *   1. The address the browser LOADED belongs to the edge (functions/_middleware.ts stamps data-seo="edge" tags from
 *      seo-route-metadata — the search-engine truth). While the visitor is still on it, the app adds no tags of its own.
 *   2. On the first move to another address the edge tags are removed once, and the app's tags take over.
 *   3. Of the app's mounted <PageSEO/>s exactly one renders: a page's own (weight 1) beats Layout's bare default
 *      (weight 0); the same weight → the last mounted.
 */
const EDGE_SEL = '[data-seo="edge"]';

function loadedPath(): string {
  if (typeof window === "undefined") return "";
  try {
    const nav = performance.getEntriesByType?.("navigation")?.[0] as PerformanceNavigationTiming | undefined;
    if (nav?.name) return new URL(nav.name).pathname;
  } catch { /* fall through */ }
  return window.location.pathname;
}

/**
 * The edge stamps where its metadata came from on its <title data-seo-src>. "default" / "fallback-error" = it knew
 * nothing about this address (e.g. /terms-of-use → the generic site title): then the app's own page tags are better,
 * so the edge does not own the head. No attribute (an older edge) = owns, as before.
 */
const GENERIC_SOURCES = new Set(["default", "fallback-error", ""]);
function edgeKnowsPage(): boolean {
  if (typeof document === "undefined") return false;
  const t = document.querySelector('title[data-seo="edge"]');
  if (!document.querySelector(EDGE_SEL)) return false;
  if (!t || !t.hasAttribute("data-seo-src")) return true;
  return !GENERIC_SOURCES.has(t.getAttribute("data-seo-src") ?? "");
}

let firstPath = loadedPath();
let edgeKnowsFirst = edgeKnowsPage();
let edgeGone = typeof document === "undefined" || !document.querySelector(EDGE_SEL);

/** True while the edge's (route-specific) tags describe the address on screen: the app must not add its own. */
export function edgeOwns(pathname: string): boolean {
  return edgeKnowsFirst && !edgeGone && pathname === firstPath;
}

/** The app takes the head (moved away, or the edge knew nothing): drop the edge's tags once — one set only. */
export function releaseEdge(): void {
  if (edgeGone) return;
  edgeGone = true;
  document.querySelectorAll(EDGE_SEL).forEach((el) => el.remove());
}

// ── which mounted <PageSEO/> renders ────────────────────────────────────────────────────────────────
const owners = new Map<number, number>(); // instance id → weight
const listeners = new Set<() => void>();
let seq = 0;

export function nextOwnerId(): number {
  return ++seq;
}

export function claimHead(id: number, weight: number): () => void {
  owners.set(id, weight);
  listeners.forEach((l) => l());
  return () => {
    owners.delete(id);
    listeners.forEach((l) => l());
  };
}

export function subscribeHead(l: () => void): () => void {
  listeners.add(l);
  return () => listeners.delete(l);
}

export function headWinner(): number {
  let best = -1;
  let bestW = -1;
  for (const [id, w] of owners) if (w > bestW || (w === bestW && id > best)) { best = id; bestW = w; }
  return best;
}

/** Tests only. */
export function __resetHeadOwner(opts: { firstPathOverride?: string } = {}): void {
  owners.clear();
  listeners.clear();
  seq = 0;
  edgeKnowsFirst = edgeKnowsPage();
  edgeGone = !document.querySelector(EDGE_SEL);
  if (opts.firstPathOverride !== undefined) firstPath = opts.firstPathOverride;
}

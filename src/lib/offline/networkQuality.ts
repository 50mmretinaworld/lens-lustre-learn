/**
 * OFF-3 · how good is the network right now? One answer for the whole app.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * Three inputs, in order of strength:
 *   1. OFFLINE — `navigator.onLine === false` (and the `offline` event).
 *   2. SLOW, declared — the Network Information API says `slow-2g`/`2g`/`3g`, a
 *      downlink under 1.5 Mbps or a round trip over 600 ms, or the member
 *      turned on Data Saver (`saveData`). Chromium/Android WebView only;
 *      absent elsewhere, which simply means "not declared".
 *   3. SLOW, observed — every Supabase read reports its outcome here (from
 *      `timeoutFetch` in the client). Over the last WINDOW reads: a median above
 *      SLOW_MEDIAN_MS, or TIMEOUTS_FOR_SLOW of OUR 25 s timeouts, is slow. An
 *      instant failure (refused, DNS) is not reported: it is not slowness, and a
 *      dead network is the browser's `offline`, input 1.
 *      This is the one input that works on every browser and on iOS.
 * It imports nothing: the Supabase client reports into it, and a module the
 * client imports must not import the client back.
 * ─────────────────────────────────────────────────────────────────────────────
 */
/**
 * reason:
 *   "offline"  — no network at all.
 *   "declared" — the browser measured the INTERNET as weak (Chromium / Android WebView).
 *   "timeouts" — reads keep hitting our 25 s timeout: something is badly wrong either way.
 *   "observed" — reads are slow, but this browser cannot say why (iOS / Safari / Firefox). Lighter images only; the
 *                status bar does NOT claim "slow connection" for it, because a slow SERVER looks exactly the same.
 *
 * Owner 23 Nov 2026 ("high speed internet but always showing this, app and web"): measured from the Owner's PC the
 * network round trip to our server is ~60 ms while a one-row read takes 250–1000 ms — the server, not the internet.
 * So where the browser reports the link itself (NetInfo), ITS answer decides; read times are ignored there.
 */
/*
 * Owner 24 Nov 2026 (screenshot, desktop Chrome, fast internet): "Still fake slow connection". Chrome's own link
 * guesses are not facts: it labels any connection whose round trip is ≥ 270 ms "3g" — normal from India to most
 * servers even on fast broadband — and its rtt/downlink numbers are estimates. So they are now "hinted": lighter
 * photos (cheap insurance), but the bar never claims "Slow connection" from a guess. The bar is kept for facts the
 * member can act on: no internet, Data Saver on, or the browser saying 2G.
 */
export type NetState = { online: boolean; slow: boolean; reason: "offline" | "declared" | "hinted" | "timeouts" | "observed" | null };

/** The reasons the status bar may name. Every other slow reason only picks lighter photos, silently. */
export function barShowsFor(s: NetState): boolean {
  return !s.online || s.reason === "declared";
}

/** Chrome's link estimate, for telemetry only (what turned "slow" on). Never throws. */
export function connectionHint(): { ect: string; rtt: number } {
  try {
    const c = (globalThis.navigator as unknown as { connection?: { effectiveType?: string; rtt?: number } } | undefined)?.connection;
    return { ect: typeof c?.effectiveType === "string" ? c.effectiveType : "na", rtt: typeof c?.rtt === "number" ? c.rtt : 0 };
  } catch {
    return { ect: "na", rtt: 0 };
  }
}

export const WINDOW = 6;
/**
 * Owner 2026-10-29: "Poor network is not handled". Measured on live the same
 * day: a feed photo is 438 KB median (p90 1.26 MB) = ~5 s each on 3G, yet only
 * 2g / Data Saver / a 3 s median counted as slow, so a weak 4G or 3G link got
 * full-size photos. Now: 3g, a declared downlink under SLOW_DOWNLINK_MBPS or a
 * round trip over SLOW_RTT_MS is slow, and the observed median threshold is
 * 1.5 s (a feed read on a good link is ~0.2–0.4 s).
 */
export const SLOW_MEDIAN_MS = 1500;
export const SLOW_DOWNLINK_MBPS = 1.5;
export const SLOW_RTT_MS = 600;
export const TIMEOUTS_FOR_SLOW = 2;

type Outcome = { ms: number; failed: boolean };
let outcomes: Outcome[] = [];
const listeners = new Set<() => void>();
let state: NetState = compute();

interface NetInfo { effectiveType?: string; saveData?: boolean; downlink?: number; rtt?: number; addEventListener?: (t: string, f: () => void) => void }

/** A FACT about the link: the member turned on Data Saver, or the browser reports 2G. */
function declaredSlow(c: NetInfo): boolean {
  if (c.saveData === true) return true;
  return c.effectiveType === "slow-2g" || c.effectiveType === "2g";
}
/** Chrome's ESTIMATE that the link may be weak ("3g" = round trip ≥ 270 ms, low downlink, high rtt): lighter photos only. */
function hintedSlow(c: NetInfo): boolean {
  if (c.effectiveType === "3g") return true;
  // 0 means "unknown" in some WebViews — never read it as slow.
  if (typeof c.downlink === "number" && c.downlink > 0 && c.downlink < SLOW_DOWNLINK_MBPS) return true;
  if (typeof c.rtt === "number" && c.rtt > SLOW_RTT_MS) return true;
  return false;
}
function connection(): NetInfo | undefined {
  try { return (globalThis.navigator as unknown as { connection?: NetInfo } | undefined)?.connection; } catch { return undefined; }
}

function compute(): NetState {
  const nav = globalThis.navigator as Navigator | undefined;
  if (nav && nav.onLine === false) return { online: false, slow: true, reason: "offline" };
  const c = connection();
  if (c && declaredSlow(c)) {
    return { online: true, slow: true, reason: "declared" };
  }
  const failures = outcomes.filter((o) => o.failed).length;
  if (failures >= TIMEOUTS_FOR_SLOW) return { online: true, slow: true, reason: "timeouts" };
  if (c && hintedSlow(c)) return { online: true, slow: true, reason: "hinted" };
  // The browser measures the link itself and calls it good: slow reads are the server, not the internet.
  if (c && typeof c.effectiveType === "string") return { online: true, slow: false, reason: null };
  const times = outcomes.filter((o) => !o.failed).map((o) => o.ms).sort((a, b) => a - b);
  const median = times.length ? times[Math.floor(times.length / 2)] : 0;
  if (outcomes.length >= 3 && median > SLOW_MEDIAN_MS) {
    return { online: true, slow: true, reason: "observed" };
  }
  return { online: true, slow: false, reason: null };
}

function update() {
  const next = compute();
  if (next.online === state.online && next.slow === state.slow && next.reason === state.reason) return;
  state = next;
  listeners.forEach((l) => { try { l(); } catch { /* a listener must not break the others */ } });
}

/** Called by the Supabase client for every read: how long it took, and whether it hit our timeout. */
export function noteOutcome(ms: number, failed: boolean) {
  outcomes = [...outcomes, { ms, failed }].slice(-WINDOW);
  update();
}

export function getNetState(): NetState { return state; }
export function subscribeNetState(fn: () => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

/** Test seam. */
export function resetNetState() { outcomes = []; state = compute(); }

let wired = false;
/** Listen to the browser's own signals. Safe to call more than once. */
export function wireBrowserSignals() {
  if (wired || typeof window === "undefined") return;
  wired = true;
  window.addEventListener("online", update);
  window.addEventListener("offline", update);
  try { connection()?.addEventListener?.("change", update); } catch { /* not supported */ }
  update();
}

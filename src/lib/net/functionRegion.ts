/**
 * N1 · RUN EVERY EDGE FUNCTION NEXT TO THE DATABASE.
 *
 * Measured 2026-11-23 from the Owner's PC (India): both Supabase projects keep
 * their database in ap-northeast-2 (Seoul), but an edge function call with no
 * region is served by the nearest edge region, ap-south-1 (Mumbai). Every
 * database step inside the function then crosses Mumbai → Seoul and back.
 * dashboard-init: median 917 ms total / 565 ms server time unpinned, 525 ms /
 * 122 ms pinned to Seoul (15 alternating calls each).
 *
 * The region goes in the `forceFunctionRegion` query parameter ONLY. The
 * `x-region` header (what functions-js sends for its `region` option) is not
 * in our functions' CORS allow-list, so a browser preflight would refuse it.
 *
 * Imports NOTHING: src/integrations/supabase/client.ts uses it, and an import
 * cycle there breaks the app shell.
 */
const DEFAULT_REGION = "ap-northeast-2";

export const FUNCTION_REGION: string =
  (import.meta.env?.VITE_SUPABASE_FUNCTION_REGION as string | undefined)?.trim() || DEFAULT_REGION;

const FUNCTIONS_PATH = "/functions/v1/";

/** Adds forceFunctionRegion to an edge function URL; any other URL comes back unchanged. */
export function pinFunctionRegion(url: string): string {
  if (!url.includes(FUNCTIONS_PATH) || url.includes("forceFunctionRegion=")) return url;
  try {
    const u = new URL(url);
    if (!u.pathname.includes(FUNCTIONS_PATH)) return url;
    u.searchParams.set("forceFunctionRegion", FUNCTION_REGION);
    return u.toString();
  } catch {
    return url;
  }
}

/** Same as pinFunctionRegion for a fetch input (string, URL or Request). */
export function pinFunctionRegionInput(input: RequestInfo | URL): RequestInfo | URL {
  if (typeof input === "string") return pinFunctionRegion(input);
  if (input instanceof URL) {
    const pinned = pinFunctionRegion(input.href);
    return pinned === input.href ? input : new URL(pinned);
  }
  const pinned = pinFunctionRegion(input.url);
  return pinned === input.url ? input : new Request(pinned, input);
}

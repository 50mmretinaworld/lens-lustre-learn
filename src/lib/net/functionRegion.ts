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
 * supabase-js always hands its fetch a string URL (functions, REST, auth), so
 * only strings are rewritten; a URL or Request object passes through as is.
 * Kept tiny on purpose: it sits in the entry bundle (P13 ceiling).
 *
 * Imports NOTHING: src/integrations/supabase/client.ts uses it, and an import
 * cycle there breaks the app shell.
 */
export const FUNCTION_REGION = "ap-northeast-2";

/** Adds forceFunctionRegion to an edge function URL; anything else comes back unchanged. */
export function pinFunctionRegion<T>(input: T): T {
  if (typeof input !== "string" || !input.includes("/functions/v1/") || input.includes("forceFunctionRegion=")) return input;
  return (input + (input.includes("?") ? "&" : "?") + "forceFunctionRegion=" + FUNCTION_REGION) as T;
}

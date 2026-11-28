// Harness only (Owner 28 Nov 2026, "badge must show everywhere a name shows"): with ?badges=1 every member the
// screen asks about (the signed-in harness member too) holds the blue Verified badge, so a real-render shot of ANY
// screen shows whether each name carries its tick. A member with no profile row (deleted) gets none, as on live.
// Off by default: the other scenes keep their no-badge baseline.

const ON = typeof location !== "undefined" && location.search.includes("badges=1");
export const badgeSampleOn = () => ON;

/** user_badges rows for exactly the ids the request names (`user_id=in.(a,b)` or `eq.a`). */
export function sampleBadgeRows(params: URLSearchParams): Array<{ user_id: string; badge_type: string }> {
  const raw = params.get("user_id") ?? "";
  const ids = raw.startsWith("in.(") ? raw.slice(4, -1).split(",") : raw.startsWith("eq.") ? [raw.slice(3)] : [];
  return ids
    .map((id) => id.replace(/^"|"$/g, ""))
    .filter((id) => id)
    .map((user_id) => ({ user_id, badge_type: "verified" }));
}

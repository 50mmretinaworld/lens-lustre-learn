import { supabase } from "@/integrations/supabase/client";
import { startPart } from "@/lib/appStart";

export const BRAND_NAME = "50mm Retina World";

// Cache admin IDs in memory for the session
let adminIdsCache: Set<string> | null = null;
let cachePromise: Promise<Set<string>> | null = null;

export function invalidateAdminIdsCache() {
  adminIdsCache = null;
  cachePromise = null;
}

/** Pre-seed admin IDs from dashboard-init (avoids independent DB query) */
export function seedAdminIds(roles: Record<string, string[]>) {
  if (adminIdsCache) return;
  const ids = new Set<string>();
  for (const [userId, userRoles] of Object.entries(roles)) {
    if (userRoles.includes("admin")) ids.add(userId);
  }
  adminIdsCache = ids;
}

/**
 * Fetch and cache admin user IDs. Uses a singleton promise to avoid duplicate requests.
 */
export async function getAdminIds(): Promise<Set<string>> {
  if (adminIdsCache) return adminIdsCache;
  if (cachePromise) return cachePromise;

  cachePromise = (async () => {
    // Use SECURITY DEFINER RPC: non-admins cannot SELECT admin rows from user_roles
    // directly (RLS restricts to own rows), which would silently return an empty set
    // and revert the admin's brand name + verified badge for every non-admin viewer.
    // N6-1: at app start the one start-up answer carries the same list (same function).
    const pre = await startPart<unknown[]>("admin_ids");
    const data = Array.isArray(pre) ? pre : (await supabase.rpc("get_public_role_user_ids" as any, { _role: "admin" })).data;
    const ids =new Set<string>((data as any[] | null || []).map((r: any) => (typeof r === "string" ? r : r.user_id ?? r)));
    adminIdsCache = ids;
    return ids;
  })();

  return cachePromise;
}

/**
 * Returns brand name if the user is an admin, otherwise the original name.
 */
export function resolveName(
  userId: string,
  originalName: string | null,
  adminIds: Set<string>
): string {
  if (adminIds.has(userId)) return BRAND_NAME;
  // Owner 13 Nov 2026: no made-up name. "" = not known yet; the name component
  // (UserIdentityBlock → useMemberName) fetches it and shows a grey bar meanwhile.
  return (originalName ?? "").trim();
}

/**
 * Ensures admin users always have a "verified" badge in their badge list.
 *
 * `originalBadges` undefined / null = the member's badges are NOT KNOWN YET (their profile has not arrived): the
 * answer is an empty list, never a guess. Owner 28 Nov 2026: in comments the official account showed a BLUE tick
 * first and then turned gold — the blue was this function guessing "verified" before the account's real badges
 * (Elite Member) had loaded. Callers pass `entry?.badges` (not `|| []`) so "not known" stays distinguishable.
 */
export function resolveBadges(
  userId: string,
  originalBadges: string[] | null | undefined,
  adminIds: Set<string>
): string[] {
  if (!originalBadges) return [];
  if (adminIds.has(userId)) {
    return originalBadges.includes("verified") ? originalBadges : ["verified", ...originalBadges];
  }
  return originalBadges;
}

/**
 * Check if a single user ID is admin (uses cached set).
 */
export function isAdminUser(userId: string, adminIds: Set<string>): boolean {
  return adminIds.has(userId);
}

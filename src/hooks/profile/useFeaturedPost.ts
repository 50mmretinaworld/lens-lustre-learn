/**
 * PREMIUM MEMBERS · PART 2 — the wall's Featured post (first-download side; the
 * honour read and the write are in usePremiumHonour.ts, loaded lazily).
 * One request: the Featured row with its post, shaped like every wall post.
 */
import { useQuery } from "@tanstack/react-query";
import { queryKeys } from "@/lib/queryKeys";
import { readFeaturedPostRow } from "@/lib/premium/featuredRead";
import { enrichPostRows } from "@/hooks/feed/useUserPostsQuery";
import type { UnifiedPost } from "@/types/post";

export function useWallFeaturedPost(userId: string | null | undefined, viewerId: string | undefined) {
  return useQuery({
    queryKey: queryKeys.premiumFeaturedPost(userId ?? ""),
    enabled: !!userId,
    retry: false,
    queryFn: async (): Promise<UnifiedPost | null> => {
      const row = await readFeaturedPostRow(userId as string);
      // A failed enrich is a failed query (retry off, no toast): the grid stays as it was.
      return row ? (await enrichPostRows([row], viewerId))[0] ?? null : null;
    },
  });
}

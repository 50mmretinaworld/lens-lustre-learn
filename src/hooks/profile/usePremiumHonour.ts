/**
 * PREMIUM MEMBERS · PART 2 — the honour hooks over src/lib/premium/honour.ts.
 * Used only by lazily loaded pieces (tick card, ⋯ menu line, Share my honour).
 *
 *   useVerifiedHonour(id)   the tick card (date), the ⋯ menu line, "Share my honour"
 *   useMarkFeaturedPost()   set / replace / clear, then every place that shows it refreshes
 *   useFeaturedPostId(id)   the ⋯ menu line (Set or Remove); the wall reads useFeaturedPost.ts
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { queryKeys } from "@/lib/queryKeys";
import { readVerifiedHonour, readFeaturedPostId, markFeaturedPost } from "@/lib/premium/honour";
import { PREMIUM_MEMBERS_KEY } from "@/hooks/feed/usePremiumMembers";
import { toast } from "@/hooks/core/use-toast";

export const FEATURED_UPDATED_TOAST = "Featured photo updated everywhere";

export function useFeaturedPostId(userId: string | null | undefined, enabled = true) {
  return useQuery({
    queryKey: queryKeys.premiumFeatured(userId ?? ""),
    enabled: enabled && !!userId,
    retry: false,
    queryFn: () => readFeaturedPostId(userId as string),
  });
}

export function useVerifiedHonour(userId: string | null | undefined, enabled = true) {
  return useQuery({
    queryKey: queryKeys.premiumHonour(userId ?? ""),
    enabled: enabled && !!userId,
    retry: false,
    queryFn: () => readVerifiedHonour(userId as string),
  });
}

export function useMarkFeaturedPost(userId: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (postId: string | null) => markFeaturedPost(postId),
    onSuccess: (_d, postId) => {
      if (userId) {
        qc.setQueryData(queryKeys.premiumFeatured(userId), postId);
        void qc.invalidateQueries({ queryKey: queryKeys.premiumFeatured(userId) });
        void qc.invalidateQueries({ queryKey: queryKeys.premiumFeaturedPost(userId) });
      }
      void qc.invalidateQueries({ queryKey: PREMIUM_MEMBERS_KEY });
      toast({ title: FEATURED_UPDATED_TOAST });
    },
    onError: (e) => {
      toast({ title: "Featured photo not changed", description: e instanceof Error ? e.message : undefined, variant: "destructive" });
    },
  });
}

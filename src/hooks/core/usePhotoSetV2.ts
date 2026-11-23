/**
 * Is `photo_set_v2` on for ME? — photo plan U2's display switch.
 *
 * The same question, cache entry and refresh rules as useFeatureAllowed
 * (featureAllowedKey, 60 s, unknown/error/signed-out = OFF), with one
 * difference: it is SAFE OUTSIDE a QueryClientProvider. U2 asks from leaf
 * components (the feed photo, a notification thumbnail) that many existing
 * tests and harness scenes render bare; there the answer is simply OFF and
 * nothing is asked — so the switch-off render stays today's render.
 */
import { useContext } from "react";
import { QueryClient, QueryClientContext, useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { FEATURE_REFRESH_MS, featureAllowedKey, featuresAllowedQuery, fetchFeatureAllowed } from "@/hooks/core/useFeatureAllowed";

/** Never fetches: every query on it is disabled. Only stands in when no provider exists. */
const INERT = new QueryClient({ defaultOptions: { queries: { enabled: false } } });

export function usePhotoSetV2(): boolean {
  const client = useContext(QueryClientContext);
  const { user } = useAuth();
  const userId = user?.id ?? null;
  const live = !!client && !!userId;
  // N3: the SAME all-switches query as useFeatureAllowed (one poll serves every switch).
  const q = useQuery(featuresAllowedQuery(userId, live), client ?? INERT);
  // A lane without the batched function: the old per-switch ask.
  const single = useQuery(
    {
      queryKey: featureAllowedKey("photo_set_v2", userId),
      enabled: live && q.isSuccess && q.data === null,
      staleTime: FEATURE_REFRESH_MS,
      refetchInterval: live ? FEATURE_REFRESH_MS : false,
      retry: false,
      queryFn: () => fetchFeatureAllowed("photo_set_v2"),
    },
    client ?? INERT,
  );
  if (!live) return false;
  return q.data === null ? single.data === true : q.data?.photo_set_v2 === true;
}

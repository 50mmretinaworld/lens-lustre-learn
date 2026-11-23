/**
 * VID-7 · is a feature switched on for ME? (`feature_allowed_me`, D1 #378)
 *
 * The answer only decides whether a button is SHOWN. The server decides whether
 * the action is ALLOWED (video_begin_upload checks the same switch), so a
 * crafted request changes nothing (VID-7).
 *
 * "Changes apply within 60 s with no app release" (R-103): re-asked every 60 s
 * while the app is open, and whenever the app comes back to the foreground.
 * Signed out, offline or on any error: false — the button stays hidden.
 *
 * N3 (Owner 23 Nov: "build like Meta"): ONE request answers EVERY switch
 * (`features_allowed_me`, 20261123_5000) instead of one request per switch per
 * minute (5 a minute on the feed). Every hook and the feed read that one answer.
 * A lane without the batched function falls back to the per-switch call.
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/core/useAuth";

export type FeatureName = "video_posts" | "video_ads" | "copyright_music_check" | "personal_feed" | "media_ladder_feed" | "media_private_photos" | "photo_upload_resume" | "photo_set_v2";

export const FEATURE_REFRESH_MS = 60_000;

export function featureAllowedKey(feature: FeatureName, userId: string | null) {
  return ["feature_allowed_me", feature, userId] as const;
}
/** The ONE query every switch reads (N3). */
export function featuresAllowedKey(userId: string | null) {
  return ["features_allowed_me", userId] as const;
}

type Rpc = (fn: string, a?: Record<string, unknown>) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
const rpc: Rpc = (fn, a) => (supabase.rpc as unknown as Rpc)(fn, a);

/** null = this lane has no batched function (fall back per switch); throws on a network failure. */
let batchMissing = false;
async function fetchAllFeatures(): Promise<Record<string, boolean> | null> {
  if (batchMissing) return null;
  const { data, error } = await rpc("features_allowed_me");
  if (error) {
    if (error.code === "PGRST202" || /could not find the function/i.test(error.message ?? "")) { batchMissing = true; return null; }
    throw new Error(error.message ?? "features_allowed_me failed");
  }
  // A real answer lists every switch (feature_access always has rows). Anything else — no body, an empty
  // object — is "not available here": the per-switch call answers instead (never "everything off").
  if (!data || typeof data !== "object" || Array.isArray(data) || Object.keys(data as object).length === 0) return null;
  return data as Record<string, boolean>;
}

/** Several asks within a few seconds share one request (the feed and the hooks mount together). */
let shared: { at: number; p: Promise<Record<string, boolean> | null> } | null = null;
export function fetchAllFeaturesShared(): Promise<Record<string, boolean> | null> {
  const now = Date.now();
  if (shared && now - shared.at < 5_000) return shared.p;
  const p = fetchAllFeatures();
  shared = { at: now, p };
  p.catch(() => { if (shared?.p === p) shared = null; });
  return p;
}

async function fetchOne(feature: FeatureName): Promise<boolean> {
  try {
    const { data, error } = await rpc("feature_allowed_me", { _feature: feature });
    if (error) return false;
    return data === true;
  } catch {
    return false;
  }
}

/**
 * One ask for one switch. Any error (offline, a lane without the switch, an
 * older database): false. Shared by the hooks below and by the feed (S12-F3),
 * which asks once when a session's first page is dealt.
 */
export async function fetchFeatureAllowed(feature: FeatureName): Promise<boolean> {
  try {
    const all = await fetchAllFeaturesShared();
    if (all === null) return fetchOne(feature);
    return all[feature] === true;
  } catch {
    return false;
  }
}

/** The shared all-switches query options (usePhotoSetV2 uses the same key, so one poll serves both). */
export function featuresAllowedQuery(userId: string | null, live: boolean) {
  return {
    queryKey: featuresAllowedKey(userId),
    enabled: live,
    staleTime: FEATURE_REFRESH_MS,
    // P10: R-103 "changes apply within 60 s, no app release" — ONE tiny RPC a
    // minute per signed-in member while the app is open (all switches at once);
    // react-query pauses it in the background.
    refetchInterval: live ? FEATURE_REFRESH_MS : (false as const),
    refetchOnWindowFocus: true,
    retry: false,
    queryFn: () => fetchAllFeaturesShared(),
  };
}

export function useFeatureAllowed(feature: FeatureName): boolean {
  const { user } = useAuth();
  const userId = user?.id ?? null;
  const q = useQuery(featuresAllowedQuery(userId, !!userId));
  // A lane without the batched function: the old per-switch ask.
  const single = useQuery({
    queryKey: featureAllowedKey(feature, userId),
    enabled: !!userId && q.isSuccess && q.data === null,
    staleTime: FEATURE_REFRESH_MS,
    refetchInterval: FEATURE_REFRESH_MS,
    retry: false,
    queryFn: () => fetchOne(feature),
  });
  // Batched answer not in yet, or a lane without it: the per-switch answer (already cached, or fetched).
  if (q.data === undefined || q.data === null) return single.data === true;
  return q.data[feature] === true;
}

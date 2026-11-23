import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getSiteSetting } from "@/lib/siteSettingsCache";
import { queryKeys } from "@/lib/queryKeys";
import { awaitDashboardBootstrap } from "@/lib/dashboardInitGate";

const FALLBACK = "/images/logo-fallback.webp";

async function fetchSiteLogo(fresh = false): Promise<string> {
  try {
    // N3 · the ONE settings reader (edge copy first, batched with the other keys asked at start).
    const value = await getSiteSetting("site_logo", fresh ? { maxAgeMs: 0 } : undefined);
    if (value) {
      let url = "";
      const v = value as unknown;
      if (typeof v === "string") {
        const trimmed = v.replace(/^"+|"+$/g, "");
        url = trimmed;
      } else if (v && typeof v === "object" && "url" in (v as any)) {
        url = (v as any).url;
      }
      if (url && url.startsWith("http")) return url;
    }
  } catch {
    /* use fallback */
  }
  return FALLBACK;
}

export function useSiteLogo() {
  const qc = useQueryClient();
  const { data: logo = FALLBACK } = useQuery({
    queryKey: queryKeys.siteLogo(),
    queryFn: async () => {
      // U-04: defer to dashboard-init seed before issuing our own fetch.
      await awaitDashboardBootstrap();
      const seeded = qc.getQueryData<string>(queryKeys.siteLogo());
      if (seeded) return seeded;
      return fetchSiteLogo(false);
    },
    staleTime: 60 * 60 * 1000, // 1 hour
  });
  return logo;
}

/** For non-React contexts (PDF generation) */
let _qc: ReturnType<typeof useQueryClient> | null = null;

export function setSiteLogoQueryClient(qc: ReturnType<typeof useQueryClient>) {
  _qc = qc;
}

export async function getSiteLogoUrl(): Promise<string> {
  // Always fetch fresh value for non-UI flows like PDF generation
  // so logo updates are reflected immediately.
  if (_qc) {
    return _qc.fetchQuery({
      queryKey: queryKeys.siteLogo(),
      queryFn: () => fetchSiteLogo(true),
      staleTime: 0,
    });
  }
  return fetchSiteLogo(true);
}

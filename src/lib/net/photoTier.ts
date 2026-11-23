/**
 * N4 · PHOTO SIZE BY MEASURED SPEED (Owner 23 Nov: "build like Meta").
 *
 * Three sizes instead of two:
 *   small   slow link (networkQuality: offline/declared/observed slow) or Data Saver → the ~600 copy
 *   medium  the browser's MEASURED download speed (navigator.connection.downlink, Chromium /
 *           Android WebView — it is computed from real traffic) is under MEDIUM_BELOW_MBPS → at most
 *           the 1080 copy on a phone, never 2048
 *   large   a fast link, or a browser that does not measure (Safari / iPhone keep today's rule:
 *           full sharpness unless the app has itself seen slow reads)
 * Same images, same srcset; only the `sizes` hint changes, so the browser picks the rung.
 */
import { useEffect, useState } from "react";
import { useNetworkQuality } from "@/hooks/core/useNetworkQuality";

export type PhotoTier = "small" | "medium" | "large";
export const MEDIUM_BELOW_MBPS = 5;
export const MEDIUM_MAX_PX = 1080;

interface NetInfo { saveData?: boolean; downlink?: number; addEventListener?: (t: string, f: () => void) => void; removeEventListener?: (t: string, f: () => void) => void }
const conn = (): NetInfo | undefined => {
  try { return (globalThis.navigator as unknown as { connection?: NetInfo } | undefined)?.connection; } catch { return undefined; }
};

export function photoTier(slow: boolean, c: NetInfo | undefined = conn()): PhotoTier {
  if (slow || c?.saveData === true) return "small";
  const d = c?.downlink;
  if (typeof d === "number" && d > 0 && d < MEDIUM_BELOW_MBPS) return "medium";   // 0 = unknown in some WebViews
  return "large";
}

/** The `sizes` hint for a feed photo at this tier. Medium: on a phone, ask for no more than the 1080 copy. */
export function feedSizesFor(tier: PhotoTier, normal: string, small: string, dpr = typeof window !== "undefined" ? window.devicePixelRatio : 1): string {
  if (tier === "small") return small;
  if (tier === "large") return normal;
  const cap = Math.max(160, Math.floor(MEDIUM_MAX_PX / Math.max(1, dpr || 1)));
  return `(max-width: 768px) ${cap}px, 600px`;
}

export function usePhotoTier(): PhotoTier {
  const { slow } = useNetworkQuality();
  const [, bump] = useState(0);
  useEffect(() => {
    const c = conn();
    if (!c?.addEventListener) return;
    const on = () => bump((n) => n + 1);   // the measured speed changed: pick again
    c.addEventListener("change", on);
    return () => c.removeEventListener?.("change", on);
  }, []);
  return photoTier(slow);
}

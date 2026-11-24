/**
 * OFF-3 · a thin banner that says what the network is doing, so a slow or empty
 * screen is never a mystery. Nothing renders on a good connection.
 *
 * Offline: the app keeps working from what OFF-1 saved on the device.
 * Slow: lighter images are loaded (PostMedia reads the same state).
 * `role="status"` + `aria-live="polite"`: announced once by a screen reader,
 * never steals focus.
 */
import { useEffect } from "react";
import { useNetworkQuality } from "@/hooks/core/useNetworkQuality";
import { useT } from "@/i18n/I18nContext";
import { useOutboxPendingCount } from "@/lib/offline/useOutboxPending";
import { barShowsFor, connectionHint } from "@/lib/offline/networkQuality";
import { recordTiming } from "@/lib/telemetry";

/** Each slow reason is recorded once per page load: `net.slow.<reason>.<chrome ect>`, duration = Chrome's rtt guess. */
const recorded = new Set<string>();

export default function NetworkBanner() {
  const net = useNetworkQuality();
  const t = useT();
  const waiting = useOutboxPendingCount();
  // Owner 24 Nov 2026 ("still fake slow connection"): measure, don't guess — which reason turned "slow" on, and what
  // Chrome estimated at that moment, lands in client_telemetry (Admin → App health).
  useEffect(() => {
    if (!net.online || !net.slow || !net.reason) return;
    const { ect, rtt } = connectionHint();
    const metric = `net.slow.${net.reason}.${ect.replace(/[^a-z0-9-]/g, "")}`;
    if (recorded.has(metric)) return;
    recorded.add(metric);
    recordTiming(metric, rtt, false);
  }, [net.online, net.slow, net.reason]);
  if (net.online && !net.slow) return null;
  // Only FACTS show the bar (no internet, Data Saver, 2G). A guess ("hinted": Chrome's 3g/rtt/downlink estimate),
  // timeouts and slow reads ("observed") only pick lighter photos — a slow server looks the same, and the bar must
  // never blame the member's internet without proof (Owner 23 + 24 Nov 2026).
  if (!barShowsFor(net)) return null;
  const offline = !net.online;
  return (
    <div
      role="status"
      aria-live="polite"
      data-testid="network-banner"
      data-state={offline ? "offline" : "slow"}
      data-reason={net.reason ?? ""}
      className={`w-full px-4 py-1.5 text-center text-xs font-medium ${offline ? "bg-muted text-foreground" : "bg-muted/70 text-muted-foreground"}`}
    >
      {offline
        ? t("net.offline", "No internet — showing saved.")
        : t("net.slow", "Slow connection — loading lighter images.")}
      {/* S7b-5: what the member did offline is kept and will be sent. */}
      {offline && waiting > 0 && (
        <span className="ml-1">
          {waiting === 1 ? "1 action will send when online." : `${waiting} actions will send when online.`}
        </span>
      )}
    </div>
  );
}

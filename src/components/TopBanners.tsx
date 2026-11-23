/**
 * THE ONE place the status bars above every page live (network: offline / slow; account under review), and the ONE
 * place their height is published: CSS variable `--banner-h` on <html> (0px when no bar shows).
 *
 * WHY (Owner 23 Nov 2026, phone screenshot): a full-height screen (chat, login, lesson…) was sized to exactly
 * 100dvh while a bar sat above it in the page flow, so the screen was pushed down by the bar's height and its bottom
 * (the message box) went off screen. Every full-height screen now subtracts `var(--banner-h)` — use the `.h-app`
 * class or `calc(100dvh - var(--banner-h))`. src/__tests__/viewportHeightBudget.test.ts fails any new in-page
 * full-height container that ignores it.
 */
import { lazy, Suspense, useLayoutEffect, useRef } from "react";
import NetworkBanner from "@/components/NetworkBanner";

const AccountStateBanner = lazy(() => import("@/components/AccountStateBanner"));

export const BANNER_HEIGHT_VAR = "--banner-h";

export default function TopBanners({ signedIn }: { signedIn: boolean }) {
  const box = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    const el = box.current;
    const root = document.documentElement;
    if (!el) return;
    const publish = () => root.style.setProperty(BANNER_HEIGHT_VAR, `${Math.round(el.getBoundingClientRect().height)}px`);
    publish();
    // ResizeObserver: every browser and WebView the app supports has it (Chrome 64+, Safari 13.1+).
    const ro = new ResizeObserver(publish);
    ro.observe(el);
    return () => {
      ro.disconnect();
      root.style.setProperty(BANNER_HEIGHT_VAR, "0px");
    };
  }, []);

  return (
    <div ref={box} data-testid="top-banners">
      {/* OFF-3: offline / slow-connection status; renders nothing on a good connection. */}
      <NetworkBanner />
      {/* A4: "Your account is under review" + support e-mail; nothing for an active member. */}
      {signedIn && <Suspense fallback={null}><AccountStateBanner /></Suspense>}
    </div>
  );
}

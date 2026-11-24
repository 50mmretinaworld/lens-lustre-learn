/**
 * THE APP FRAME — what a page's "whole screen" is inside Layout.
 *
 * Owner 24 Nov 2026 (iPhone): "all screens have a scroll bar … all screens must be screen-wise tight".
 * Measured in WebKit at iPhone size (app mode): every page that sets `min-h-screen` (100 % of the phone)
 * sat inside a frame that already puts a 48 px top bar above it and keeps 48 px of room for the bottom bar
 * below it — so even an empty screen was 96 px taller than the phone and scrolled.
 *
 * The frame now publishes the top bar's height as `--frame-top` on <html> (0 px when the bar floats OVER the
 * page — the home hero — or is hidden, e.g. a phone chat). index.css `.app-frame .min-h-screen` subtracts it,
 * the status bars (`--banner-h`, TopBanners) and the bottom-bar room (`--frame-bottom`), so a short screen is
 * exactly as tall as the phone. One rule for every page; no page carries its own number.
 */
import { useLayoutEffect, useRef } from "react";

export const FRAME_TOP_VAR = "--frame-top";

/**
 * Screens that never show the phone's bottom tab bar (sign-in pages, admin) — read by the bar (MobileBottomNav) and
 * by the frame (Layout), so the frame keeps no room for a bar that is not there. STAGING PORT of main's
 * lib/appBar isBottomBarHidden (#1240; main also hides it on a phone chat, which staging does not have).
 */
const NO_BOTTOM_BAR_PREFIXES = ["/login", "/signup", "/forgot-password", "/reset-password", "/admin"];
export function isBottomBarHidden(pathname: string): boolean {
  return NO_BOTTOM_BAR_PREFIXES.some((p) => pathname.startsWith(p));
}

/** Height the element takes IN the page flow: 0 when it floats (absolute/fixed) or is not shown. */
export function inFlowHeight(el: HTMLElement | null): number {
  if (!el) return 0;
  const pos = getComputedStyle(el).position;
  if (pos === "absolute" || pos === "fixed") return 0;
  return Math.round(el.getBoundingClientRect().height);
}

/** Ref for the top-bar wrapper; keeps `--frame-top` equal to its in-flow height (route changes, resizes). */
export function usePublishFrameTop(routeKey: string) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const root = document.documentElement;
    const el = ref.current;
    const publish = () => root.style.setProperty(FRAME_TOP_VAR, `${inFlowHeight(ref.current)}px`);
    publish();
    if (!el || typeof ResizeObserver === "undefined") return () => root.style.setProperty(FRAME_TOP_VAR, "0px");
    // ResizeObserver: every browser and WebView the app supports has it (Chrome 64+, Safari 13.1+).
    const ro = new ResizeObserver(publish);
    ro.observe(el);
    window.addEventListener("resize", publish);
    return () => {
      ro.disconnect();
      window.removeEventListener("resize", publish);
      root.style.setProperty(FRAME_TOP_VAR, "0px");
    };
  }, [routeKey]);
  return ref;
}

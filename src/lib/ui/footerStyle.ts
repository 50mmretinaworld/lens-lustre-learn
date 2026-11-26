/**
 * THE APP FOOTER STYLE — one place for how the bottom bar looks and moves.
 *
 * Owner 26 Nov 2026 (sample A approved): in the Android and iPhone apps the bar floats above the bottom edge, thin and
 * classic (44 px, 36 px while reading down the page), soft corners, a blue line on the current tab, and the big 50mm
 * button rises out of it and beats like a heart. The website is unchanged.
 *
 * Who gets it: Admin → Features → "App footer: floating" (switch `floating_footer`, 20261126_6500) — Off / Selected
 * members / All members, read from the database, so it changes without a new build. Signed out: classic.
 */
import { useEffect, useState } from "react";
import { isNativeCapacitorApp } from "@/lib/native/authDeepLink";
import { useFeatureAllowed } from "@/hooks/core/useFeatureAllowed";

/** On <html> while the floating bar is shown: index.css keeps its room under the page. */
export const FOOTER_FLOATING_CLASS = "footer-floating";

/** Scroll distance (px) before the bar changes size, and the top zone where it is always full. */
const STEP = 6;
const TOP_ZONE = 40;

export function useFooterStyle(pathname: string) {
  const allowed = useFeatureAllowed("floating_footer");
  const floating = allowed && isNativeCapacitorApp();
  const [compact, setCompact] = useState(false);

  useEffect(() => {
    if (!floating) return;
    const root = document.documentElement;
    root.classList.add(FOOTER_FLOATING_CLASS);
    return () => root.classList.remove(FOOTER_FLOATING_CLASS);
  }, [floating]);

  // Reading down → small; scrolling back (or near the top, or a new screen) → full.
  useEffect(() => {
    setCompact(false);
    if (!floating) return;
    let last = window.scrollY;
    const onScroll = () => {
      const y = window.scrollY;
      const d = y - last;
      if (y < TOP_ZONE) setCompact(false);
      else if (d > STEP) setCompact(true);
      else if (d < -STEP) setCompact(false);
      if (Math.abs(d) > STEP) last = y;
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, [floating, pathname]);

  // Asked only for the floating bar, and not with framer's useReducedMotion: that one warns in the console.
  const reduceMotion = floating && !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

  return { floating, compact: floating && compact, reduceMotion };
}

/** Class names for both styles. `classic` is the bar every build had before; it must not change. */
export const footerClasses = (floating: boolean, compact: boolean) => ({
  nav: floating
    ? `fixed z-50 bg-card/70 backdrop-blur-2xl backdrop-saturate-150 border border-border/50 shadow-[0_8px_30px_rgba(0,0,0,0.45)] lg:hidden transition-all duration-300 bottom-[max(8px,calc(var(--safe-bottom)-14px))] ${compact ? "left-12 right-12 rounded-[12px]" : "left-3 right-3 rounded-[14px]"}`
    : "fixed bottom-0 left-0 right-0 z-50 bg-card/60 backdrop-blur-2xl backdrop-saturate-150 border-t border-border/25 lg:hidden safe-area-bottom",
  row: floating
    ? `flex items-center justify-around px-1 relative transition-all duration-300 ${compact ? "h-[36px] [&_svg]:h-[18px] [&_svg]:w-[18px]" : "h-[44px] [&_svg]:h-[22px] [&_svg]:w-[22px]"}`
    : "flex items-center justify-around h-12 px-1 relative",
  homeLink: `flex flex-col items-center flex-1 relative group ${
    floating ? `self-end mb-1 justify-end transition-all duration-300 ${compact ? "-mt-5" : "-mt-6"}` : "justify-end -mt-4"
  }`,
  homeBox: `relative flex items-center justify-center ${floating ? (compact ? "h-11 w-11" : "h-[58px] w-[58px]") : "h-12 w-12"}`,
  homeDisc: floating ? "h-full w-full" : "h-12 w-12",
  homeLogo: floating ? "h-full w-full" : "h-11 w-11",
  avatar: floating ? (compact ? "h-5 w-5" : "h-6 w-6") : "h-7 w-7",
  indicator: floating ? "absolute top-0 left-1/4 right-1/4 h-0.5 bg-primary rounded-full" : "absolute -top-px left-1/4 right-1/4 h-0.5 bg-primary rounded-full",
  tab: floating ? "self-stretch" : "",
});

/** The 50mm button's motion. Floating: a double heartbeat then a rest. Reduced motion: still. */
export function homePulse(floating: boolean, reduceMotion: boolean) {
  if (reduceMotion && floating) return { glow: {}, disc: {}, transition: { duration: 0 } };
  const transition = { repeat: Infinity, duration: floating ? 1.6 : 2.8, ease: "easeInOut" as const };
  return floating
    ? { glow: { scale: [1, 1.35, 1.05, 1.25, 1, 1], opacity: [0.35, 0.85, 0.45, 0.7, 0.35, 0.35] }, disc: { scale: [1, 1.14, 1, 1.09, 1, 1], y: [0, -4, 0, -2, 0, 0] }, transition }
    : { glow: { scale: [1, 1.18, 1], opacity: [0.35, 0.7, 0.35] }, disc: { scale: [1, 1.08, 1] }, transition };
}

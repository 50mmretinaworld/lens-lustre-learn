import { isNativeIOSApp } from "@/lib/native/authDeepLink";

/**
 * THE PHONE'S OWN STATUS BAR — iPhone app only.
 *
 * Owner 26 Nov 2026, iPhone app screenshots: the logo sat on top of the time, the camera island and the battery; the
 * top bar (+ create post, name, menu) and page headers were half under them. The iPhone web view starts at the very
 * top of the glass and nothing in the app reserved that strip.
 *
 * `viewport-fit=cover` is what makes iOS report the strip to the page as `env(safe-area-inset-top)` (without it the
 * value is 0 and the page cannot know). The `app-ios` class on <html> switches on THE one rule in src/index.css
 * ("THE PHONE'S OWN STATUS BAR"), which turns that value into `--safe-top` for every top bar, overlay and full-height
 * screen. The website and the Android app get neither, so they render exactly as before (Android's web view already
 * starts below its status bar — capacitor.config.ts adjustMarginsForEdgeToEdge).
 */
export const SAFE_AREA_CLASS = "app-ios";

/** The installed app's viewport (no focus zoom — see zoomPolicy.ts) plus, on the iPhone app, viewport-fit=cover. */
export function appViewport(base: string): string {
  return isNativeIOSApp() ? `${base}, viewport-fit=cover` : base;
}

/** Puts the class on <html> inside the iPhone app; no-op everywhere else. Returns whether it applied. */
export function installSafeArea(): boolean {
  if (!isNativeIOSApp()) return false;
  document.documentElement.classList.add(SAFE_AREA_CLASS);
  return true;
}

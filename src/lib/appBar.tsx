/**
 * The app's top bar on a phone, per screen (Owner 22 Nov 2026: "pro app — an inner screen has a back arrow and its own
 * title; a chat is full screen"). ONE rule for the whole app:
 *   · a main screen (Feed, Home, Chat list, Compete, your own wall) keeps the bar as it is: [+] 50MM RETINA WORLD [☰];
 *   · an inner screen asks for its own bar with useAppBar({ title, actions }) — the bar then shows [←] title [actions] [☰];
 *   · a chat (/messages/<chat> and /messages/with/<member>) is full screen on a phone: no top bar, no bottom tab bar —
 *     the chat's own header carries the back arrow.
 * Pages never draw a second top bar of their own.
 */
import { useEffect, useRef, useSyncExternalStore, type ReactNode } from "react";

export interface AppBarSpec { title: ReactNode; actions?: ReactNode }

let current: (AppBarSpec & { owner: object }) | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

export function useAppBarSpec(): (AppBarSpec & { owner: object }) | null {
  return useSyncExternalStore(
    (l) => { listeners.add(l); return () => { listeners.delete(l); }; },
    () => current,
    () => null,
  );
}

/** An inner screen's own top bar (← title … actions). Cleared when the screen goes away. */
export function useAppBar(spec: AppBarSpec | null) {
  const owner = useRef({}).current;
  // follow the page's title / menu as they change…
  useEffect(() => {
    if (!spec) return;
    current = { ...spec, owner };
    emit();
  }, [spec, owner]);
  // …and give the bar back when the page goes away (only if it is still ours)
  useEffect(() => () => {
    if (current?.owner === owner) { current = null; emit(); }
  }, [owner]);
}

/** The same, as an element — for a page whose early returns make a hook call awkward: render it where the page is drawn. */
export function PageAppBar({ title, actions }: AppBarSpec) {
  // a new spec each render keeps the bar in step with the page (the title or the menu may change); the store only re-renders
  // the top bar, never the page, so this cannot loop
  useAppBar({ title, actions });
  return null;
}

/** A chat: full screen on a phone (no app top bar, no bottom tab bar). */
export function isChatScreen(pathname: string): boolean {
  if (pathname.startsWith("/messages/with/")) return true;
  const m = /^\/messages\/([^/]+)\/?$/.exec(pathname);
  return !!m && m[1] !== "requests";
}

/** Screens that never show the phone's bottom tab bar (sign-in pages, admin, a phone chat). */
const NO_BOTTOM_BAR_PREFIXES = ["/login", "/signup", "/forgot-password", "/reset-password", "/admin"];

/**
 * THE rule for "does this screen have the bottom tab bar?" — read by the bar itself (MobileBottomNav) AND by the app
 * frame (Layout), so the frame never keeps room for a bar that is not there. Owner 24 Nov (iPhone): "all screens must
 * be screen-wise tight" — measured live: Login and Sign up were 900 px on an 852 px phone (48 px of bar room, no bar).
 */
export function isBottomBarHidden(pathname: string): boolean {
  return NO_BOTTOM_BAR_PREFIXES.some((p) => pathname.startsWith(p)) || isChatScreen(pathname);
}

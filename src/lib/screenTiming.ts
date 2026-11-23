/**
 * N5 · SPEED PER SCREEN (Owner 23 Nov: "build like Meta"). ONE shared clock for every screen.
 *
 * What it measures: how long a member waits from the tap that opened a screen (or from the app
 * starting, for the first screen — "cold") until the screen shows its content. Reported through
 * the existing telemetry (client_telemetry, timing kind) as `screen.<name>` / `screen.<name>.cold`,
 * so Admin → App health reads typical and slowest times per screen, per app, per day.
 *
 * Each screen calls useScreenReady(name, ready) once its content (saved copy or fresh) is on screen.
 * Recorded once per page change per screen. Never throws, never blocks the UI (telemetry rule 1).
 */
import { useEffect } from "react";
import { useLocation } from "react-router-dom";
import { recordTiming } from "@/lib/telemetry";

let navAt = 0;            // performance.now() of the last page change; 0 = the app starting
let pageChanges = 0;
const done = new Set<string>();

export function notePageChange(): void {
  try { navAt = performance.now(); pageChanges += 1; done.clear(); } catch { /* never affects the app */ }
}

export function screenReady(name: string): void {
  try {
    if (done.has(name)) return;
    done.add(name);
    const cold = pageChanges === 0;
    recordTiming(`screen.${name}${cold ? ".cold" : ""}`, performance.now() - navAt, true);
  } catch { /* rule 1 */ }
}

export function useScreenReady(name: string, ready: boolean): void {
  useEffect(() => { if (ready) screenReady(name); }, [name, ready]);
}

/** Mounted once inside the router: every page change restarts the clock (the first page is "cold"). */
export function ScreenClock(): null {
  const { pathname } = useLocation();
  useEffect(() => {
    if (first) { first = false; return; }
    notePageChange();
  }, [pathname]);
  return null;
}
let first = true;

/** Tests only. */
export function resetScreenTimingForTests(): void { navAt = 0; pageChanges = 0; done.clear(); first = true; }

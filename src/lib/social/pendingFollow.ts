/**
 * THE FOLLOW A SIGNED-OUT VISITOR ASKED FOR (Premium Members, Part 4b, Owner 26 Nov 2026):
 * "After joining, the follow they asked for is done automatically."
 *
 * Kept on this device only, one at a time (the latest tap wins), and done ONCE
 * after sign-in by PendingFollowRunner, which then clears it. Every storage
 * call is guarded: a private window or blocked storage simply means no
 * remembered follow, never an error.
 *
 * The start-up gate in App.tsx (first download) reads only pendingFollowFlag.ts;
 * this file loads on demand.
 */
import { PENDING_FOLLOW_KEY } from "@/lib/social/pendingFollowFlag";

export { PENDING_FOLLOW_KEY, hasPendingFollow } from "@/lib/social/pendingFollowFlag";

export interface PendingFollow {
  id: string;
  name: string;
}

export function savePendingFollow(p: PendingFollow): void {
  try {
    localStorage.setItem(PENDING_FOLLOW_KEY, JSON.stringify({ id: p.id, name: p.name }));
  } catch { /* storage blocked: nothing remembered */ }
}

export function readPendingFollow(): PendingFollow | null {
  try {
    const raw = localStorage.getItem(PENDING_FOLLOW_KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as Partial<PendingFollow>;
    return typeof v?.id === "string" && v.id ? { id: v.id, name: typeof v.name === "string" ? v.name : "" } : null;
  } catch {
    return null;
  }
}

export function clearPendingFollow(): void {
  try {
    localStorage.removeItem(PENDING_FOLLOW_KEY);
  } catch { /* ignore */ }
}

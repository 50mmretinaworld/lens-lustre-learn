/** The start-up check alone (App.tsx's gate, first download); the rest is in pendingFollow.ts, on demand. */
export const PENDING_FOLLOW_KEY = "50mm.pendingFollow";

export function hasPendingFollow(): boolean {
  try {
    return !!localStorage.getItem(PENDING_FOLLOW_KEY);
  } catch {
    return false;
  }
}

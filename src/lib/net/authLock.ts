/**
 * THE SIGN-IN LOCK THAT NEVER MAKES A SCREEN WAIT FOR ANOTHER TAB.
 *
 * supabase-js makes every tab take turns on ONE browser lock around the saved session, and every data request asks
 * for it first. A tab that does not let go (typically a background tab Chrome froze in the middle of a token
 * refresh) stalled all the others: 10 s then an error (24 Nov), then 5 s on EVERY request. Measured on the live
 * site 26 Nov 2026 with the lock held by a second tab: first data request 10.3 s instead of ~1 s (Owner: "every
 * screen takes 5 to 10 seconds").
 *
 * Now: wait OTHER_TAB_WAIT_MS once. Still held → carry on with this tab's own lock, and while it stays held do not
 * wait at all (take it only if it is free). The worst case is two tabs refreshing the session at once, which the
 * server accepts (a refresh token may be reused for a few seconds). The background refresh's "is anyone
 * refreshing? then skip" (acquireTimeout 0) is unchanged.
 */
export type LockFn = <R>(name: string, acquireTimeout: number, fn: () => Promise<R>) => Promise<R>;

export const OTHER_TAB_WAIT_MS = 800;

export function makeAuthLock(shared: LockFn, own: LockFn): LockFn {
  let stuck = false;
  return async function authLock<R>(name: string, acquireTimeout: number, fn: () => Promise<R>): Promise<R> {
    const hasLocks = typeof globalThis.navigator !== "undefined" && !!(globalThis.navigator as Navigator & { locks?: unknown }).locks;
    if (!hasLocks) return own(name, acquireTimeout, fn);
    if (acquireTimeout === 0) return shared(name, 0, fn);
    const wait = stuck ? 0 : acquireTimeout < 0 ? OTHER_TAB_WAIT_MS : Math.min(acquireTimeout, OTHER_TAB_WAIT_MS);
    try {
      return await shared(name, wait, () => { stuck = false; return fn(); });
    } catch (err) {
      if ((err as { isAcquireTimeout?: unknown } | null)?.isAcquireTimeout !== true) throw err;
      stuck = true;
      return own(name, -1, fn);
    }
  };
}

/**
 * A tab that does not let go of the sign-in lock must not stall the others (Owner 26 Nov 2026: "every screen takes
 * 5 to 10 seconds"). src/lib/net/authLock.ts.
 */
import { describe, it, expect, vi, beforeAll, afterAll } from "vitest";
import { makeAuthLock, OTHER_TAB_WAIT_MS, type LockFn } from "@/lib/net/authLock";

const had = Object.getOwnPropertyDescriptor(globalThis.navigator, "locks");
beforeAll(() => { Object.defineProperty(globalThis.navigator, "locks", { value: {}, configurable: true }); });
afterAll(() => {
  if (had) Object.defineProperty(globalThis.navigator, "locks", had);
  else delete (globalThis.navigator as unknown as { locks?: unknown }).locks;
});

function setup() {
  const state = { held: true, waits: [] as number[] };
  const shared: LockFn = async (_name, wait, fn) => {
    state.waits.push(wait);
    if (state.held) throw Object.assign(new Error("timed out"), { isAcquireTimeout: true });
    return fn();
  };
  const own = vi.fn(async (_n: string, _w: number, fn: () => Promise<unknown>) => fn()) as unknown as LockFn;
  return { state, lock: makeAuthLock(shared, own) };
}

describe("authLock", () => {
  it("waits once, then not at all while the other tab keeps it", async () => {
    const { state, lock } = setup();
    expect(await lock("l", 10_000, async () => 1)).toBe(1);
    expect(await lock("l", -1, async () => 2)).toBe(2);
    expect(await lock("l", 10_000, async () => 3)).toBe(3);
    expect(state.waits).toEqual([OTHER_TAB_WAIT_MS, 0, 0]);
    expect(OTHER_TAB_WAIT_MS).toBeLessThanOrEqual(1000);
  });

  it("goes back to taking turns once the lock is free again", async () => {
    const { state, lock } = setup();
    await lock("l", 10_000, async () => 1);
    state.held = false;
    await lock("l", 10_000, async () => 2);
    await lock("l", 10_000, async () => 3);
    expect(state.waits).toEqual([OTHER_TAB_WAIT_MS, 0, OTHER_TAB_WAIT_MS]);
  });

  it("keeps the background refresh's skip, and passes real errors on", async () => {
    const { state, lock } = setup();
    await expect(lock("l", 0, async () => 1)).rejects.toMatchObject({ isAcquireTimeout: true });
    state.held = false;
    await expect(lock("l", 10_000, async () => { throw new Error("boom"); })).rejects.toThrow("boom");
  });
});

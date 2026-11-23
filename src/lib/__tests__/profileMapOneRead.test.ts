/**
 * N3 (Owner 23 Nov: "build like Meta"): a signed-in member's name + online dot come from ONE read of
 * profiles_public_data (was two). If that read is refused, the name-only read answers — names never go
 * missing. Signed out: the two reads as before (the online dot is not readable without a session).
 */
import { describe, it, expect, vi, beforeEach } from "vitest";

type Ask = { table: string; select: string };
let asks: Ask[] = [];
let refuseCombined = false;
const ROW = { id: "u1", full_name: "Mira Sen", avatar_url: null, custom_url: "mira", last_active_at: "2026-11-23T12:00:00Z" };

function table(name: string) {
  return {
    select: (cols: string) => ({
      in: async () => {
        asks.push({ table: name, select: cols });
        if (name === "profiles_public_data" && cols.includes("last_active_at") && cols.includes("full_name") && refuseCombined) {
          return { data: null, error: { code: "42501", message: "permission denied for column last_active_at" } };
        }
        if (name === "user_badges") return { data: [], error: null };
        return { data: [ROW], error: null };
      },
    }),
  };
}
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    from: (t: string) => table(t),
    rpc: async () => ({ data: [], error: null }),
    channel: () => ({ on: () => ({ subscribe: () => ({}) }), subscribe: () => ({}) }),
    removeChannel: () => {},
  },
}));

async function load(signedIn: string | null) {
  vi.resetModules();
  const logger = await import("@/lib/logger");
  logger.setLogUser(signedIn);
  return import("@/lib/profileMapCache");
}
const reads = () => asks.filter((a) => a.table === "profiles_public_data").length;

beforeEach(() => {
  asks = [];
  refuseCombined = false;
});

describe("profile lookup: name + online dot in one read when signed in (N3)", () => {
  it("signed in → ONE profiles read carries the name and the online dot", async () => {
    const { fetchProfileMapDirect } = await load("viewer-1");
    const map = await fetchProfileMapDirect(["u1"]);
    expect(reads()).toBe(1);
    expect(map.get("u1")).toMatchObject({ full_name: "Mira Sen", last_active_at: "2026-11-23T12:00:00Z" });
  });

  it("signed in but the read is refused → the name-only read answers; the name is there", async () => {
    refuseCombined = true;
    const { fetchProfileMapDirect } = await load("viewer-1");
    const map = await fetchProfileMapDirect(["u1"]);
    expect(map.get("u1")?.full_name).toBe("Mira Sen");
  });

  it("signed out, no session on the device → ONE read (the name); the online-dot read the server refuses is not sent", async () => {
    localStorage.clear();
    const { fetchProfileMapDirect } = await load(null);
    const map = await fetchProfileMapDirect(["u1"]);
    expect(reads()).toBe(1);
    expect(asks.some((a) => a.select === "id, last_active_at")).toBe(false);
    expect(map.get("u1")?.full_name).toBe("Mira Sen");
  });

  it("a session is stored but the auth hook has not reported yet → the two reads as before (dots not lost)", async () => {
    localStorage.setItem("sb-testprojectref0000x-auth-token", "{}");
    try {
      const { fetchProfileMapDirect } = await load(null);
      await fetchProfileMapDirect(["u1"]);
      expect(reads()).toBe(2);
    } finally {
      localStorage.clear();
    }
  });
});

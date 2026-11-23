/**
 * N3 3b · THE FEED'S FIRST PAGE IS ONE ROUND TRIP (Owner 23 Nov: "build like Meta").
 *
 * The REAL useFeedQuery and supabase-js against a fake PostgREST. "personal feed?" is held back
 * (it is slow on a phone in India); once this device knows the answer, the page call goes out
 * WITHOUT waiting for it. On a device that never asked, the old order stays (ask first, once).
 */
import React from "react";
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

const h = vi.hoisted(() => ({
  fetchImpl: null as null | ((i: RequestInfo | URL, init?: RequestInit) => Promise<Response>),
}));

vi.mock("@/integrations/supabase/client", async () => {
  const { createClient } = await import("@supabase/supabase-js");
  return {
    supabase: createClient("https://testprojectref0000x.supabase.co", "test-key", {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { fetch: ((i: RequestInfo | URL, init?: RequestInit) => h.fetchImpl!(i, init)) as typeof fetch },
    }),
  };
});

const { useFeedQuery, __resetSessionSeedRpcProbe } = await import("@/hooks/feed/useFeedQuery");
const { clearFeedSessions } = await import("@/lib/feedSessions");

const ME = "00000000-0000-4000-8000-0000000000aa";
const uuid = (n: number) => `10000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const POOL = Array.from({ length: 20 }, (_, i) => ({
  id: uuid(i), user_id: `20000000-0000-4000-8000-${String(i % 5).padStart(12, "0")}`, content: `post ${i}`, image_url: null, image_urls: [],
  privacy: "public", created_at: new Date(Date.UTC(2026, 9, 1, 0, i)).toISOString(), likes_count: 0, comments_count: 0, shares_count: 0,
  feed_tier: "unseen", author_name: "A", author_avatar: null, thumbnail_urls: null, categories: [],
}));
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

let order: string[];
let releaseFlag: () => void;
let qc: QueryClient;
beforeEach(() => {
  localStorage.clear();
  clearFeedSessions();
  __resetSessionSeedRpcProbe({ cursor: false });
  order = [];
  const gate = new Promise<void>((r) => { releaseFlag = r; });
  h.fetchImpl = async (input, init) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const body = typeof init?.body === "string" ? (JSON.parse(init.body) as Record<string, unknown>) : {};
    const m = url.pathname.match(/^\/rest\/v1\/rpc\/(.+)$/);
    if (m) {
      order.push(`start:${m[1]}`);
      if (m[1] === "feature_allowed_me") { await gate; order.push("answer:feature_allowed_me"); return json(200, false); }
      if (m[1] === "get_broadcast_feed") return json(200, POOL.slice(0, Number(body._limit)));
    }
    if (url.pathname === "/rest/v1/posts" && url.searchParams.get("select") === "created_at") return json(200, [{ created_at: POOL[0].created_at }]);
    return json(200, []);
  };
  qc = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } });
});
afterEach(() => { vi.restoreAllMocks(); qc.clear(); });

function mount() {
  const wrapper = ({ children }: { children: React.ReactNode }) => React.createElement(QueryClientProvider, { client: qc }, children);
  return renderHook(() => useFeedQuery(ME), { wrapper });
}

describe("N3 3b · feed first page in one round trip", () => {
  it("the device knows the answer: the page call goes out before 'personal feed?' answers", async () => {
    localStorage.setItem(`feed-personal:${ME}`, "0");
    const { result } = mount();
    await waitFor(() => expect(order).toContain("start:get_broadcast_feed"));
    expect(order).not.toContain("answer:feature_allowed_me");   // still held back
    releaseFlag();
    await waitFor(() => expect(result.current.data?.pages?.[0]?.posts.length ?? 0).toBeGreaterThan(0));
  });

  it("a device that never asked keeps the old order once, then remembers", async () => {
    const { result } = mount();
    await waitFor(() => expect(order).toContain("start:feature_allowed_me"));
    await new Promise((r) => setTimeout(r, 50));
    expect(order).not.toContain("start:get_broadcast_feed");    // waits for the answer this once
    releaseFlag();
    await waitFor(() => expect(result.current.data?.pages?.[0]?.posts.length ?? 0).toBeGreaterThan(0));
    expect(localStorage.getItem(`feed-personal:${ME}`)).toBe("0");
  });
});

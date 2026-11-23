/**
 * N3 (Owner 23 Nov: "build like Meta"): every feature switch comes from ONE request
 * (features_allowed_me, SQL 20261123_5000). A lane without that function falls back to
 * the old per-switch call — never "everything off".
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { ReactNode } from "react";
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

let batch: "ok" | "missing" = "ok";
const rpc = vi.fn(async (fn: string, args?: Record<string, unknown>) => {
  if (fn === "features_allowed_me") {
    if (batch === "missing") return { data: null, error: { code: "PGRST202", message: "Could not find the function public.features_allowed_me" } };
    return { data: { video_posts: true, photo_set_v2: true, video_ads: false }, error: null };
  }
  if (fn === "feature_allowed_me") return { data: args?._feature === "video_posts", error: null };
  return { data: null, error: null };
});
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: (fn: string, a?: Record<string, unknown>) => rpc(fn, a) } }));
vi.mock("@/hooks/core/useAuth", () => ({ useAuth: () => ({ user: { id: "m1" }, loading: false }) }));

async function load() {
  vi.resetModules(); // the module keeps "batch missing" + a 5 s shared answer: start clean each test
  const fa = await import("@/hooks/core/useFeatureAllowed");
  const ps = await import("@/hooks/core/usePhotoSetV2");
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  return { ...fa, ...ps, wrapper };
}
const calls = (fn: string) => rpc.mock.calls.filter((c) => c[0] === fn).length;

beforeEach(() => {
  rpc.mockClear();
  batch = "ok";
});

describe("feature switches: one request for all (N3)", () => {
  it("three switches on one screen → ONE features_allowed_me request, no per-switch calls", async () => {
    const { useFeatureAllowed, usePhotoSetV2, wrapper } = await load();
    const { result } = renderHook(
      () => ({ v: useFeatureAllowed("video_posts"), a: useFeatureAllowed("video_ads"), p: usePhotoSetV2() }),
      { wrapper },
    );
    await waitFor(() => expect(result.current).toEqual({ v: true, a: false, p: true }));
    expect(calls("features_allowed_me")).toBe(1);
    expect(calls("feature_allowed_me")).toBe(0);
  });

  it("a lane without the batched function → the old per-switch call answers", async () => {
    batch = "missing";
    const { useFeatureAllowed, wrapper } = await load();
    const { result } = renderHook(() => ({ v: useFeatureAllowed("video_posts"), a: useFeatureAllowed("video_ads") }), { wrapper });
    await waitFor(() => expect(result.current).toEqual({ v: true, a: false }));
    expect(calls("feature_allowed_me")).toBe(2);
  });

  it("the feed's one-off ask (fetchFeatureAllowed) reads the same shared answer", async () => {
    const { fetchFeatureAllowed } = await load();
    expect(await Promise.all([fetchFeatureAllowed("video_posts"), fetchFeatureAllowed("video_ads")])).toEqual([true, false]);
    expect(calls("features_allowed_me")).toBe(1);
  });
});

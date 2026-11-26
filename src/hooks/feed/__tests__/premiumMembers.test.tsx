/**
 * PREMIUM MEMBERS — the one reader degrades to NOTHING (Owner-approved plan, 26 Nov 2026).
 * The server function (PR #1277) may not be on a lane yet: an error or a throw
 * must give an empty list (row and grid then render nothing), never an error toast.
 */
import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

const h = vi.hoisted(() => ({ rpc: vi.fn(), toast: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: h.rpc, from: vi.fn() } }));
vi.mock("@/hooks/core/useAuth", () => ({ useAuth: () => ({ user: null }) }));
vi.mock("@/hooks/core/use-toast", () => ({ toast: h.toast, useToast: () => ({ toast: h.toast }) }));

const { usePremiumMembers, parsePremiumMembers, PREMIUM_MEMBERS_LIMIT } = await import("@/hooks/feed/usePremiumMembers");

const wrap = () => {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
};

const ROW = {
  user_id: "u1", full_name: "Neil Basu", handle: "neil.basu", avatar_url: null, post_id: "p1",
  photo_url: "https://cdn/x.webp", thumb_url: null, is_featured: true, line: "A steady eye.",
  line_is_citation: true, honoured_at: "2026-11-20T10:00:00Z", follower_count: 12,
};

describe("usePremiumMembers", () => {
  beforeEach(() => { h.rpc.mockReset(); h.toast.mockReset(); });

  it("asks the one server function, signed out, with the page limit", async () => {
    h.rpc.mockResolvedValue({ data: [ROW], error: null });
    const { result } = renderHook(() => usePremiumMembers(), { wrapper: wrap() });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(h.rpc).toHaveBeenCalledWith("get_premium_members", { _limit: PREMIUM_MEMBERS_LIMIT });
    expect(result.current.data?.map((m) => m.full_name)).toEqual(["Neil Basu"]);
  });

  it("an RPC error (function not on this database yet) → empty list, no toast", async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: "Could not find the function public.get_premium_members" } });
    const { result } = renderHook(() => usePremiumMembers(), { wrapper: wrap() });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toEqual([]);
    expect(result.current.isError).toBe(false);
    expect(h.toast).not.toHaveBeenCalled();
  });

  it("a thrown network failure → empty list, not an error state", async () => {
    h.rpc.mockRejectedValue(new TypeError("Failed to fetch"));
    const { result } = renderHook(() => usePremiumMembers(), { wrapper: wrap() });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toEqual([]);
    expect(h.toast).not.toHaveBeenCalled();
  });
});

describe("parsePremiumMembers", () => {
  it("drops rows with no id and gives every field a safe default", () => {
    const out = parsePremiumMembers([ROW, { full_name: "no id" }, null, { user_id: "u2" }]);
    expect(out.map((m) => m.user_id)).toEqual(["u1", "u2"]);
    expect(out[1]).toMatchObject({ full_name: "Member", line: null, line_is_citation: false, is_featured: false, handle: null });
  });
  it("anything but an array is an empty list", () => {
    expect(parsePremiumMembers(null)).toEqual([]);
    expect(parsePremiumMembers({})).toEqual([]);
  });
});

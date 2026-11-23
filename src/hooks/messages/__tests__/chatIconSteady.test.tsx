/**
 * Owner 23 Nov: "in App and Web Chat icon in poor network moving out coming in".
 * A failed check must never read as "not allowed", and the device's last answer shows at once.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, waitFor, act } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";

const rpc = vi.fn();
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));
vi.mock("@/hooks/core/useAuth", () => ({ useAuth: () => ({ user: { id: "u1" }, loading: false }) }));

import { useMessagingAllowed } from "@/hooks/messages/useMessagingAllowed";

function wrap() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const W = ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  return { qc, W };
}

describe("Chat icon stays put on a poor network", () => {
  beforeEach(() => { rpc.mockReset(); localStorage.clear(); });

  it("a failed re-check keeps the icon (last answer stays)", async () => {
    rpc.mockResolvedValueOnce({ data: true, error: null });
    const { qc, W } = wrap();
    const { result } = renderHook(() => useMessagingAllowed(), { wrapper: W });
    await waitFor(() => expect(result.current).toBe(true));
    rpc.mockResolvedValueOnce({ data: null, error: { message: "Request timed out" } });
    await act(async () => { await qc.refetchQueries(); });
    expect(result.current).toBe(true);
  });

  it("the device's last answer shows on the first frame", () => {
    localStorage.setItem("msg-allowed:u1", "1");
    rpc.mockReturnValue(new Promise(() => {})); // network never answers
    const { W } = wrap();
    const { result } = renderHook(() => useMessagingAllowed(), { wrapper: W });
    expect(result.current).toBe(true);
  });

  it("a real 'no' from the server still hides it, and is remembered", async () => {
    localStorage.setItem("msg-allowed:u1", "1");
    rpc.mockResolvedValueOnce({ data: false, error: null });
    const { W } = wrap();
    const { result } = renderHook(() => useMessagingAllowed(), { wrapper: W });
    await waitFor(() => expect(result.current).toBe(false));
    expect(localStorage.getItem("msg-allowed:u1")).toBe("0");
  });
});

/**
 * A4 · the signed-in member's own account state, for the under-review banner.
 *
 * One read of public.my_account_state() (20261115_1310): 'active' when the
 * member may act, 'under_review' otherwise (an admin hold, or a pending
 * deletion request — the member can only look while it waits). The database
 * guard (zz_account_state_guard) is what actually blocks writes; this hook only
 * tells the member why.
 *
 * Fails quiet: on a lane without the function, or any error, it reports
 * 'active' so no banner shows — a wrong banner is worse than a missing one.
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/core/useAuth";
import { queryKeys } from "@/lib/queryKeys";
import { startPart } from "@/lib/appStart";

export type MyAccountState = "active" | "under_review";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

/** Shape guard: only the exact string 'under_review' turns the banner on. */
export function parseMyAccountState(data: unknown): MyAccountState {
  return data === "under_review" ? "under_review" : "active";
}

export async function fetchMyAccountState(): Promise<MyAccountState> {
  try {
    // N6-1: at app start the one start-up answer carries it (same function).
    const pre = await startPart<string>("account_state");
    if (typeof pre === "string") return parseMyAccountState(pre);
    const { data, error } = await rpc("my_account_state");
    if (error) return "active";
    return parseMyAccountState(data);
  } catch {
    return "active";
  }
}

export const useMyAccountState = () => {
  const { user, loading: authLoading } = useAuth();
  const { data = "active" } = useQuery({
    queryKey: queryKeys.myAccountState(user?.id ?? ""),
    queryFn: fetchMyAccountState,
    enabled: !!user && !authLoading,
  });
  return user ? data : "active";
};

/**
 * A4 · admin account review — reads and the four admin actions.
 *
 * Every call is an admin-only SECURITY DEFINER rpc from 20261115_1310 / 1330;
 * each one checks has_role(admin) itself and refuses an empty reason, so the
 * client never decides who may act. Every action writes account_state_log
 * (kept 1 year), which admin_account_state_history reads back.
 *
 *   admin_set_account_state(_user_id, 'under_review' | 'active', _reason)
 *   admin_decide_deletion(_user_id, 'approve' | 'hold', _reason)   — member asked to be deleted
 *   admin_delete_member(_user_id, _reason)                         — instant full wipe
 */
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { queryKeys } from "@/lib/queryKeys";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export interface AccountReviewRow {
  user_id: string;
  full_name: string | null;
  state: "under_review" | "deletion_requested";
  reason: string | null;
  set_at: string;
  set_by_name: string | null;
  deletion_requested_at: string | null;
  auto_approve_at: string | null;
}

export interface AccountStateLogRow {
  created_at: string;
  from_state: string | null;
  to_state: string;
  reason: string | null;
  actor_name: string | null;
}

const str = (v: unknown) => (typeof v === "string" ? v : null);

/** Shape guard: a malformed row is dropped, never the page. */
export function parseAccountReviews(data: unknown): AccountReviewRow[] {
  if (!Array.isArray(data)) return [];
  return data.flatMap((r) => {
    if (!r || typeof r !== "object") return [];
    const o = r as Record<string, unknown>;
    if (typeof o.user_id !== "string" || typeof o.set_at !== "string") return [];
    if (o.state !== "under_review" && o.state !== "deletion_requested") return [];
    return [{
      user_id: o.user_id,
      full_name: str(o.full_name),
      state: o.state,
      reason: str(o.reason),
      set_at: o.set_at,
      set_by_name: str(o.set_by_name),
      deletion_requested_at: str(o.deletion_requested_at),
      auto_approve_at: str(o.auto_approve_at),
    }];
  });
}

export function parseAccountStateLog(data: unknown): AccountStateLogRow[] {
  if (!Array.isArray(data)) return [];
  return data.flatMap((r) => {
    if (!r || typeof r !== "object") return [];
    const o = r as Record<string, unknown>;
    if (typeof o.created_at !== "string" || typeof o.to_state !== "string") return [];
    return [{ created_at: o.created_at, from_state: str(o.from_state), to_state: o.to_state, reason: str(o.reason), actor_name: str(o.actor_name) }];
  });
}

async function call(fn: string, args?: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await rpc(fn, args);
  if (error) throw new Error(error.message ?? "request failed");
  return data;
}

export const useAccountReviews = () =>
  useQuery({
    queryKey: queryKeys.accountReviews(),
    queryFn: async () => parseAccountReviews(await call("admin_list_account_reviews")),
    staleTime: 0,
  });

export const useAccountStateHistory = (userId: string | null) =>
  useQuery({
    queryKey: queryKeys.accountStateHistory(userId ?? ""),
    queryFn: async () => parseAccountStateLog(await call("admin_account_state_history", { _user_id: userId })),
    enabled: !!userId,
    staleTime: 0,
  });

export type AccountAction =
  | { kind: "under_review"; userId: string; reason: string }
  | { kind: "active"; userId: string; reason: string }
  | { kind: "approve"; userId: string; reason: string }
  | { kind: "hold"; userId: string; reason: string }
  | { kind: "delete"; userId: string; reason: string };

/** One action → one rpc. Exported for the test. */
export function actionCall(a: AccountAction): [string, Record<string, unknown>] {
  switch (a.kind) {
    case "under_review":
    case "active":
      return ["admin_set_account_state", { _user_id: a.userId, _state: a.kind, _reason: a.reason }];
    case "approve":
    case "hold":
      return ["admin_decide_deletion", { _user_id: a.userId, _decision: a.kind, _reason: a.reason }];
    case "delete":
      return ["admin_delete_member", { _user_id: a.userId, _reason: a.reason }];
  }
}

export const useAccountAction = () => {
  const qc = useQueryClient();
  return async (a: AccountAction) => {
    if (!a.reason.trim()) throw new Error("a reason is required");
    const [fn, args] = actionCall(a);
    const out = await call(fn, args);
    await qc.invalidateQueries({ queryKey: queryKeys.accountReviews() });
    await qc.invalidateQueries({ queryKey: queryKeys.accountStateHistory(a.userId) });
    return out;
  };
};

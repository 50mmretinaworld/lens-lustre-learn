/**
 * Admin → Users table — reads and the member writes, in one place.
 *
 * READ: one admin-only rpc returns everything a row shows (roles, badges,
 * activity, status), filtered, sorted and paged IN SQL — before the limit, so
 * no member can fall off a page (the 2026-08-21 lesson in AdminUsers.tsx).
 *   admin_search_users_v4(_query, _role, _badge, _platform, _status, _active, _sort, _limit, _offset)
 *   admin_user_facets(_query, _role, _badge, _platform, _status, _active)
 *     → status counts (every filter but status) + platform counts (every filter but platform)
 *
 * STATUS — one per member, the order account_can_act() blocks in:
 *   banned (profiles.is_banned) › suspended (profiles.is_suspended) ›
 *   deletion_requested › under_review (account_states) › active.
 *
 * WRITES: roles, badges, name/bio and suspension are the same table writes
 * the old list made (unchanged rules, RLS decides). Under review / active /
 * delete go through useAccountAction (A4) — never a copy here.
 */
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { queryKeys } from "@/lib/queryKeys";
import { invalidateRoleCache } from "@/components/AutoRole";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string; code?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export const MEMBER_STATUSES = ["active", "suspended", "banned", "under_review", "deletion_requested"] as const;
export type MemberStatus = (typeof MEMBER_STATUSES)[number];
export type MemberSort = "joined_desc" | "joined_asc" | "name_asc" | "name_desc" | "active_desc" | "active_asc";
export type MemberPlatform = "" | "app" | "web" | "unknown";
export type MemberActive = "" | "24h" | "7d" | "30d" | "inactive90";

export interface MemberFilters {
  query: string;
  role: string;
  badge: string;
  platform: MemberPlatform;
  status: "" | MemberStatus;
  active: MemberActive;
  sort: MemberSort;
  page: number;
  pageSize: number;
}

export const DEFAULT_MEMBER_FILTERS: MemberFilters = {
  query: "", role: "", badge: "", platform: "", status: "", active: "", sort: "joined_desc", page: 0, pageSize: 50,
};

export interface AdminMember {
  id: string;
  email: string | null;
  full_name: string | null;
  avatar_url: string | null;
  custom_url: string | null;
  bio: string | null;
  created_at: string;
  last_active_at: string | null;
  last_platform: "app" | "web" | null;
  roles: string[];
  badges: string[];
  status: MemberStatus;
  suspended_until: string | null;
  suspension_reason: string | null;
  review_reason: string | null;
}

export interface MemberFacets {
  status: Record<"all" | MemberStatus, number>;
  platform: Record<"all" | "app" | "web" | "unknown", number>;
}

const s = (v: unknown) => (typeof v === "string" ? v : null);
const arr = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
const n = (v: unknown) => Number(v ?? 0) || 0;

/** Shape guard: a malformed row is dropped, never the page. Exported for the test. */
export function parseMembers(data: unknown): { rows: AdminMember[]; total: number } {
  if (!Array.isArray(data)) return { rows: [], total: 0 };
  const rows = data.flatMap((r): AdminMember[] => {
    if (!r || typeof r !== "object") return [];
    const o = r as Record<string, unknown>;
    if (typeof o.id !== "string" || typeof o.created_at !== "string") return [];
    const status = (MEMBER_STATUSES as readonly string[]).includes(o.status as string) ? (o.status as MemberStatus) : "active";
    return [{
      id: o.id, email: s(o.email), full_name: s(o.full_name), avatar_url: s(o.avatar_url), custom_url: s(o.custom_url),
      bio: s(o.bio), created_at: o.created_at, last_active_at: s(o.last_active_at),
      last_platform: o.last_platform === "app" || o.last_platform === "web" ? o.last_platform : null,
      roles: arr(o.roles), badges: arr(o.badges), status,
      suspended_until: s(o.suspended_until), suspension_reason: s(o.suspension_reason), review_reason: s(o.review_reason),
    }];
  });
  const first = data[0] as Record<string, unknown> | undefined;
  return { rows, total: first ? n(first.total_count) : 0 };
}

export function parseFacets(data: unknown): MemberFacets | null {
  const o = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined;
  if (!o || typeof o !== "object") return null;
  return {
    status: {
      all: n(o.all_count), active: n(o.active_count), suspended: n(o.suspended_count), banned: n(o.banned_count),
      under_review: n(o.under_review_count), deletion_requested: n(o.deletion_requested_count),
    },
    platform: { all: n(o.platform_all_count), app: n(o.app_count), web: n(o.web_count), unknown: n(o.unknown_count) },
  };
}

/** PostgREST "no such function" / Postgres undefined_function: a lane without the v4 migration. */
export class MembersRpcMissing extends Error {}
const isMissing = (e: { code?: string } | null) => !!e && (e.code === "PGRST202" || e.code === "42883");

const baseArgs = (f: MemberFilters) => ({
  _query: f.query.trim(), _role: f.role || null, _badge: f.badge || null, _platform: f.platform || null,
  _status: f.status || null, _active: f.active || null,
});

export const useAdminMembers = (f: MemberFilters) =>
  useQuery({
    queryKey: [...queryKeys.adminMembers(), f],
    queryFn: async () => {
      const [list, facets] = await Promise.all([
        rpc("admin_search_users_v4", { ...baseArgs(f), _sort: f.sort, _limit: f.pageSize, _offset: f.page * f.pageSize }),
        rpc("admin_user_facets", baseArgs(f)),
      ]);
      if (isMissing(list.error)) throw new MembersRpcMissing("admin_search_users_v4 is not on this database yet");
      if (list.error) throw new Error(list.error.message ?? "search failed");
      return { ...parseMembers(list.data), facets: facets.error ? null : parseFacets(facets.data) };
    },
    placeholderData: keepPreviousData,
    staleTime: 15_000,
    retry: false,
  });

/** The member writes the table offers. Each returns an error message, or null when done. */
export const useMemberWrites = (adminId: string | null) => {
  const qc = useQueryClient();
  const refresh = () => qc.invalidateQueries({ queryKey: queryKeys.adminMembers() });
  const roleCaches = (userId: string) => {
    invalidateRoleCache(userId);
    void qc.invalidateQueries({ queryKey: queryKeys.isAdmin(userId) });
    void qc.invalidateQueries({ queryKey: ["user-roles", userId] });
    void qc.invalidateQueries({ queryKey: queryKeys.profileMapPrefix() });
    void qc.invalidateQueries({ queryKey: ["dashboard-init"] });
  };
  const done = async (error: { message?: string; code?: string } | null, after?: () => void) => {
    if (error && error.code !== "23505") return error.message ?? "failed";
    after?.();
    await refresh();
    return null;
  };

  return {
    refresh,
    setRole: async (userId: string, role: string, on: boolean) => {
      if (!on && role === "user") return "The base user role cannot be removed";
      const { error } = on
        ? await supabase.from("user_roles").insert({ user_id: userId, role: role as never })
        : await supabase.from("user_roles").delete().eq("user_id", userId).eq("role", role as never);
      return done(error, () => roleCaches(userId));
    },
    setBadge: async (userId: string, badge: string, on: boolean) => {
      const { error } = on
        ? await supabase.from("user_badges").insert({ user_id: userId, badge_type: badge, assigned_by: adminId } as never)
        : await supabase.from("user_badges").delete().eq("user_id", userId).eq("badge_type", badge);
      return done(error, () => {
        void qc.invalidateQueries({ queryKey: queryKeys.profileMapPrefix() });
        void qc.invalidateQueries({ queryKey: ["dashboard-init"] });
      });
    },
    suspend: async (userId: string, days: number | null, reason: string) => {
      const { error } = await supabase.from("profiles").update({
        is_suspended: true,
        suspension_reason: reason.trim() || "Suspended by admin",
        suspended_until: days === null ? null : new Date(Date.now() + days * 86_400_000).toISOString(),
      } as never).eq("id", userId);
      return done(error);
    },
    liftSuspension: async (userId: string) => {
      const { error } = await supabase.from("profiles").update({
        is_suspended: false, suspended_until: null, suspension_reason: null,
      } as never).eq("id", userId);
      return done(error);
    },
    saveProfile: async (userId: string, fullName: string, bio: string) => {
      const { error } = await supabase.from("profiles").update({
        full_name: fullName.trim() || null, bio: bio.trim() || null, updated_at: new Date().toISOString(),
      } as never).eq("id", userId);
      return done(error);
    },
  };
};

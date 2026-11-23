/**
 * Admin → Users: which app each member uses (Owner, 2026-11-23: "write which
 * App version each user is using; who is using an old version / last updated
 * version … iOS too"). One hook file for the three reads of SQL 4400 (M34):
 *
 *   admin_app_versions()                         → the versions card
 *   admin_member_apps(_ids)                      → the App column + drawer line (rows on screen, ≤ 200)
 *   admin_app_version_members(_os, _version, …)  → the members behind one card row
 *
 * The data is what every signed-in app start already reports
 * (push_permission_state; older builds only left a push token without a
 * version). A database without M34 answers "missing" — the card and the
 * column then hide themselves, the rest of the page is unchanged.
 */
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { queryKeys } from "@/lib/queryKeys";
import { isOldVersion, newestVersion, sortVersionsDesc } from "@/lib/versionCompare";
import type { AdminMember } from "@/hooks/admin/useAdminMembers";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string; code?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);
const isMissing = (e: { code?: string } | null) => !!e && (e.code === "PGRST202" || e.code === "42883");

export type AppOs = "android" | "ios";
/** A card row / member list: one build, all older apps without a version, or website only. */
export type AppGroup = { os: AppOs; version: string } | { os: "older" } | { os: "web" };

export interface MemberApp {
  os: AppOs | null;
  version: string | null;
  seenAt: string | null;
  push: "on" | "off" | null;
}

export interface VersionRow { os: AppOs; version: string; members: number; active7d: number; lastSeen: string | null }
export interface AppVersionSummary {
  checkedAt: string | null;
  /** Newest first per OS. */
  android: VersionRow[];
  ios: VersionRow[];
  newest: Record<AppOs, string | null>;
  older: { members: number; active7d: number };
  website: { members: number; active7d: number };
  notRecorded: number;
  total: number;
}

export interface AppVersionMember {
  id: string; full_name: string | null; avatar_url: string | null; custom_url: string | null;
  os: AppOs | null; version: string | null; seenAt: string | null;
}

const num = (v: unknown) => Number(v ?? 0) || 0;
const str = (v: unknown) => (typeof v === "string" && v ? v : null);
const osOf = (v: unknown): AppOs | null => (v === "android" || v === "ios" ? v : null);
const pair = (v: unknown) => {
  const o = (v && typeof v === "object" ? v : {}) as Record<string, unknown>;
  return { members: num(o.members), active7d: num(o.active_7d) };
};

/** Shape guards — exported for the test. A malformed row is dropped, never the card. */
export function parseSummary(data: unknown): AppVersionSummary | null {
  const o = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | null | undefined;
  if (!o || typeof o !== "object") return null;
  const rows: VersionRow[] = (Array.isArray(o.versions) ? o.versions : []).flatMap((r): VersionRow[] => {
    const x = (r ?? {}) as Record<string, unknown>;
    const os = osOf(x.os);
    const version = str(x.version);
    return os && version ? [{ os, version, members: num(x.members), active7d: num(x.active_7d), lastSeen: str(x.last_seen) }] : [];
  });
  const android = sortVersionsDesc(rows.filter((r) => r.os === "android"), (r) => r.version);
  const ios = sortVersionsDesc(rows.filter((r) => r.os === "ios"), (r) => r.version);
  return {
    checkedAt: str(o.checked_at),
    android, ios,
    newest: { android: android[0]?.version ?? null, ios: ios[0]?.version ?? null },
    older: pair(o.older_app), website: pair(o.website_only),
    notRecorded: num(o.not_recorded), total: num(o.total),
  };
}

export function parseMemberApps(data: unknown): Map<string, MemberApp> {
  const out = new Map<string, MemberApp>();
  if (!Array.isArray(data)) return out;
  for (const r of data) {
    const x = (r ?? {}) as Record<string, unknown>;
    if (typeof x.user_id !== "string") continue;
    out.set(x.user_id, {
      os: osOf(x.os), version: str(x.app_version), seenAt: str(x.seen_at),
      push: x.push === "on" || x.push === "off" ? x.push : null,
    });
  }
  return out;
}

export function parseVersionMembers(data: unknown): { rows: AppVersionMember[]; total: number } {
  if (!Array.isArray(data)) return { rows: [], total: 0 };
  const rows = data.flatMap((r): AppVersionMember[] => {
    const x = (r ?? {}) as Record<string, unknown>;
    if (typeof x.id !== "string") return [];
    return [{ id: x.id, full_name: str(x.full_name), avatar_url: str(x.avatar_url), custom_url: str(x.custom_url), os: osOf(x.os), version: str(x.app_version), seenAt: str(x.seen_at) }];
  });
  const first = data[0] as Record<string, unknown> | undefined;
  return { rows, total: first ? num(first.total_count) : 0 };
}

/** The versions card. `data === null` with no error: the database has no M34 yet → hide. */
export const useAppVersionSummary = (enabled = true) =>
  useQuery({
    queryKey: [...queryKeys.adminAppVersions(), "summary"],
    enabled,
    queryFn: async () => {
      const { data, error } = await rpc("admin_app_versions");
      if (isMissing(error)) return null;
      if (error) throw new Error(error.message ?? "app versions failed");
      return parseSummary(data);
    },
    staleTime: 60_000,
    retry: false,
  });

/** The App column: app info for the members on screen. `null` = no M34 → hide the column. */
export const useMemberApps = (ids: string[]) => {
  const key = [...ids].sort().join(",");
  return useQuery({
    queryKey: [...queryKeys.adminAppVersions(), "members", key],
    enabled: ids.length > 0,
    queryFn: async () => {
      const { data, error } = await rpc("admin_member_apps", { _ids: ids.slice(0, 200) });
      if (isMissing(error)) return null;
      if (error) throw new Error(error.message ?? "member apps failed");
      return parseMemberApps(data);
    },
    placeholderData: keepPreviousData,
    staleTime: 30_000,
    retry: false,
  });
};

export const VERSION_MEMBERS_PAGE = 50;

/** The members behind one card row, newest "last opened" first. */
export const useAppVersionMembers = (group: AppGroup | null, page: number) =>
  useQuery({
    queryKey: [...queryKeys.adminAppVersions(), "list", group?.os ?? "", group && "version" in group ? group.version : "", page],
    enabled: !!group,
    queryFn: async () => {
      const { data, error } = await rpc("admin_app_version_members", {
        _os: group!.os, _version: "version" in group! ? group.version : null,
        _limit: VERSION_MEMBERS_PAGE, _offset: page * VERSION_MEMBERS_PAGE,
      });
      if (error) throw new Error(error.message ?? "members failed");
      return parseVersionMembers(data);
    },
    placeholderData: keepPreviousData,
    staleTime: 30_000,
    retry: false,
  });

/**
 * What one member's App line says — the one rule the column, the phone card
 * and the drawer all draw from.
 *   kind "app"    Android / iPhone + version (old = below the newest seen for that OS)
 *   kind "older"  an app without a version recorded (Android before 1.2.50)
 *   kind "web"    no app record; last signed in on the website
 *   kind "none"   nothing recorded
 */
export type AppLine =
  | { kind: "app"; os: AppOs; version: string | null; old: boolean; latest: boolean; seenAt: string | null; push: MemberApp["push"] }
  | { kind: "older"; os: AppOs | null; seenAt: string | null; push: MemberApp["push"] }
  | { kind: "web" }
  | { kind: "none" };

export function appLineOf(
  m: Pick<AdminMember, "last_platform" | "last_active_at">,
  app: MemberApp | undefined,
  newest: Record<AppOs, string | null>,
): AppLine {
  if (app?.os && app.version) {
    return {
      kind: "app", os: app.os, version: app.version, seenAt: app.seenAt, push: app.push,
      old: isOldVersion(app.version, newest[app.os]), latest: !!newest[app.os] && !isOldVersion(app.version, newest[app.os]),
    };
  }
  if (app?.os) return { kind: "older", os: app.os, seenAt: app.seenAt, push: app.push };
  if (m.last_platform === "app") return { kind: "older", os: null, seenAt: m.last_active_at, push: null };
  if (m.last_platform === "web") return { kind: "web" };
  return { kind: "none" };
}

/** Newest per OS: from the card when it loaded, else from the rows on screen. */
export function newestOf(summary: AppVersionSummary | null | undefined, apps: Map<string, MemberApp> | null | undefined): Record<AppOs, string | null> {
  if (summary) return summary.newest;
  const list = [...(apps?.values() ?? [])];
  return {
    android: newestVersion(list.filter((a) => a.os === "android").map((a) => a.version)),
    ios: newestVersion(list.filter((a) => a.os === "ios").map((a) => a.version)),
  };
}

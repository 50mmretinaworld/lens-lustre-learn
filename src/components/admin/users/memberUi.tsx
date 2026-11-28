/**
 * Admin → Users: the small pieces every part of the table draws the same way —
 * status chip, member avatar, role/badge labels. One copy each.
 */
import { cn } from "@/lib/utils";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { useBadgeDefinitions } from "@/hooks/profile/useBadgeDefinitions";
import { useRoleDefinitions } from "@/hooks/profile/useRoleDefinitions";
import type { AdminMember, MemberStatus } from "@/hooks/admin/useAdminMembers";

export const STATUS_META: Record<MemberStatus, { label: string; dot: string; chip: string }> = {
  active: { label: "Active", dot: "bg-emerald-500", chip: "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300" },
  suspended: { label: "Suspended", dot: "bg-amber-500", chip: "border-amber-500/40 bg-amber-500/10 text-amber-700 dark:text-amber-300" },
  banned: { label: "Banned", dot: "bg-red-500", chip: "border-red-500/40 bg-red-500/10 text-red-700 dark:text-red-300" },
  under_review: { label: "Under review", dot: "bg-violet-500", chip: "border-violet-500/40 bg-violet-500/10 text-violet-700 dark:text-violet-300" },
  deletion_requested: { label: "Asked to delete", dot: "bg-rose-500", chip: "border-rose-500/40 bg-rose-500/10 text-rose-700 dark:text-rose-300" },
};

const shortDate = (iso: string) => new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });

/** "Suspended · until 21 Nov 2026" — the second line under a chip, when there is one. */
export function statusDetail(m: AdminMember): string | null {
  if (m.status === "suspended") {
    if (!m.suspended_until) return "Until lifted";
    return Date.parse(m.suspended_until) > Date.now() ? `Until ${shortDate(m.suspended_until)}` : `Ended ${shortDate(m.suspended_until)} · still on`;
  }
  return null;
}

export function StatusChip({ status, className }: { status: MemberStatus; className?: string }) {
  const m = STATUS_META[status];
  return (
    <span className={cn("inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border px-2 py-0.5 text-xs font-medium", m.chip, className)} data-testid={`status-${status}`}>
      <span className={cn("h-1.5 w-1.5 rounded-full", m.dot)} aria-hidden />
      {m.label}
    </span>
  );
}

export function MemberAvatar({ m, size = 36 }: { m: Pick<AdminMember, "avatar_url" | "full_name" | "email">; size?: number }) {
  return (
    <Avatar style={{ width: size, height: size }} className="shrink-0 border border-border">
      {m.avatar_url && <AvatarImage src={m.avatar_url} alt="" referrerPolicy="no-referrer" className="object-cover" />}
      <AvatarFallback className="bg-muted text-sm font-medium text-muted-foreground">
        {(m.full_name || m.email || "?")[0]?.toUpperCase()}
      </AvatarFallback>
    </Avatar>
  );
}

const ROLE_FALLBACK: Record<string, string> = {
  user: "User", admin: "Admin", judge: "Jury", content_editor: "Contributor", registered_photographer: "Photographer", student: "Student",
};
const SYSTEM_ROLES = Object.keys(ROLE_FALLBACK);

/** Role and badge names, icons and colours from the definitions tables (Badge & Role Types tab). */
export function useMemberLabels() {
  const roleDefs = useRoleDefinitions();
  const badgeDefs = useBadgeDefinitions();
  const allRoles = Array.from(new Set([...roleDefs.keys(), ...SYSTEM_ROLES]));
  return {
    allRoles,
    allBadges: Array.from(badgeDefs.keys()),
    role: (r: string) => ({
      label: roleDefs.get(r)?.label ?? ROLE_FALLBACK[r] ?? r.replace(/_/g, " "),
      icon: roleDefs.get(r)?.icon ?? "",
      cls: roleDefs.get(r)?.pill_class ?? "bg-muted text-muted-foreground border-border",
    }),
    badge: (b: string) => ({
      label: badgeDefs.get(b)?.label ?? b.replace(/_/g, " "),
      icon: badgeDefs.get(b)?.icon ?? "⭐",
      cls: badgeDefs.get(b)?.badge_class ?? "bg-amber-500/15 text-amber-600 border-amber-500/30",
    }),
  };
}

export type MemberLabels = ReturnType<typeof useMemberLabels>;

/** Roles (not the base "user") and badges as small pills; `max` folds the rest into "+N". */
export function RolePills({ m, labels, max }: { m: AdminMember; labels: MemberLabels; max?: number }) {
  const items = [
    ...m.roles.filter((r) => r !== "user").map((r) => ({ key: `r-${r}`, ...labels.role(r) })),
    ...m.badges.map((b) => ({ key: `b-${b}`, ...labels.badge(b) })),
  ];
  if (!items.length) return <span className="text-xs text-muted-foreground">—</span>;
  const shown = max ? items.slice(0, max) : items;
  return (
    <span className="flex flex-wrap gap-1">
      {shown.map((i) => (
        <span key={i.key} className={cn("inline-flex items-center gap-1 whitespace-nowrap rounded-md border px-1.5 py-0.5 text-[11px]", i.cls)}>
          {i.icon && <span aria-hidden>{i.icon}</span>}{i.label}
        </span>
      ))}
      {items.length > shown.length && <span className="rounded-md border border-border px-1.5 py-0.5 text-[11px] text-muted-foreground">+{items.length - shown.length}</span>}
    </span>
  );
}

export const fmtDate = shortDate;

/**
 * Admin → Users shows EXACT times, always in India time (Owner bug list 28 Nov, item 17: "don't show 15w ago …
 * exact date and time … always IST"). e.g. "28 Nov 2026, 10:15 am IST". null / bad input → null.
 */
const IST = new Intl.DateTimeFormat("en-IN", {
  timeZone: "Asia/Kolkata", day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit", hour12: true,
});
export function istDateTime(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? `${IST.format(new Date(t)).replace(/\b(am|pm)\b/i, (x) => x.toLowerCase())} IST` : null;
}

/**
 * EVERY platform the member is known to use, latest first (Owner 28 Nov: "Neil Basu uses App and Web both but
 * showing only Web"). `last_platform` is only where the LATEST session was; a phone that reported an app version
 * proves the app is used too, so it is listed even when the latest visit was the website. One rule for the table,
 * the phone list and the drawer.
 */
export function platformsUsed(m: { last_platform?: string | null; app_version?: string | null; app_os?: string | null }):
  Array<{ kind: "app" | "web"; label: string; latest: boolean }> {
  const out: Array<{ kind: "app" | "web"; label: string; latest: boolean }> = [];
  if (m.last_platform === "web") out.push({ kind: "web", label: "Website", latest: true });
  if (m.last_platform === "app" || m.app_version) out.push({ kind: "app", label: appLabel(m), latest: m.last_platform === "app" });
  return out;
}

/** "App 1.2.63 · Android" when the phone reported its version, else just "App". */
export function appLabel(m: { app_version?: string | null; app_os?: string | null }): string {
  if (!m.app_version) return "App";
  const os = m.app_os === "ios" ? "iPhone" : m.app_os === "android" ? "Android" : null;
  return `App ${m.app_version}${os ? ` · ${os}` : ""}`;
}

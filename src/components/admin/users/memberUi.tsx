/**
 * Admin → Users: the small pieces every part of the table draws the same way —
 * status chip, member avatar, role/badge labels. One copy each.
 */
import { cn } from "@/lib/utils";
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
  const style = { width: size, height: size };
  if (m.avatar_url) {
    return <img referrerPolicy="no-referrer" loading="lazy" decoding="async" src={m.avatar_url} alt="" style={style} className="shrink-0 rounded-full border border-border object-cover" />;
  }
  return (
    <span style={style} className="flex shrink-0 items-center justify-center rounded-full border border-border bg-muted text-sm font-medium text-muted-foreground" aria-hidden>
      {(m.full_name || m.email || "?")[0]?.toUpperCase()}
    </span>
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

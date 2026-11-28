/**
 * Admin → Users — the members table (Owner, 2026-11-16: "Now vs New UI ...
 * suspended / banned users can't see").
 *
 * - Status tabs with counts: All · Active · Suspended · Banned · Under review ·
 *   Asked to delete. Every filter, the sort and the paging run IN SQL
 *   (useAdminMembers), so a tab never shows only the loaded page.
 * - One search box (name, e-mail or @handle), Role / Badge / Platform / Last
 *   active filters, sortable Member · Last active · Joined, rows per page.
 * - Row select + bulk bar; row menu; click a member for the full panel
 *   (MemberDrawer). Phone width: cards + a Filters sheet.
 * - Under review / active / delete = the A4 actions (AccountActionDialog),
 *   the same ones Account Review uses.
 * - A database without admin_search_users_v4 gets the previous list
 *   (AdminUsers) instead of a broken page.
 */
import { lazy, Suspense, useEffect, useMemo, useRef, useState } from "react";
import type { User as AuthUser } from "@supabase/supabase-js";
import {
  Search, X, ChevronDown, ChevronUp, ChevronsUpDown, MoreHorizontal, SlidersHorizontal, Columns3,
  ChevronLeft, ChevronRight, Smartphone, Globe, Ban, ShieldCheck, ShieldAlert, UserCheck, Trash2,
  ExternalLink, UserCog, Loader2, CheckCircle2, PauseCircle, Plus, Minus,
} from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useQueryClient } from "@tanstack/react-query";
import { queryKeys } from "@/lib/queryKeys";
import { cn } from "@/lib/utils";
import { memberPath } from "@/lib/urlHelpers";
import { useIsMobile } from "@/hooks/core/use-mobile";
import { useOnlineIds } from "@/lib/presence/online";
import { formatLastSeen } from "@/hooks/core/useLastActive";
import { toast } from "@/hooks/core/use-toast";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { Textarea } from "@/components/ui/textarea";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import {
  DropdownMenu, DropdownMenuCheckboxItem, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel,
  DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import ConfirmDialog from "@/components/admin/ConfirmDialog";
import { useConfirmAction } from "@/hooks/admin/useConfirmAction";
import { AccountActionDialog, type PendingAccountAction } from "@/components/admin/AccountActionDialog";
import {
  DEFAULT_MEMBER_FILTERS, MembersRpcMissing, useAdminMembers, useMemberWrites,
  type AdminMember, type MemberFilters, type MemberSort, type MemberStatus,
} from "@/hooks/admin/useAdminMembers";
import { MemberAvatar, RolePills, StatusChip, STATUS_META, appLabel, fmtDate, istDateTime, statusDetail, useMemberLabels } from "./memberUi";
import { MemberDrawer, type MemberActions } from "./MemberDrawer";

const AdminUsersPrevious = lazy(() => import("@/components/admin/AdminUsers"));

const STATUS_TABS: { key: "" | MemberStatus; label: string }[] = [
  { key: "", label: "All" },
  { key: "active", label: "Active" },
  { key: "suspended", label: "Suspended" },
  { key: "banned", label: "Banned" },
  { key: "under_review", label: "Under review" },
  { key: "deletion_requested", label: "Asked to delete" },
];
const ACTIVE_OPTIONS = [
  { key: "", label: "Any time" }, { key: "24h", label: "Last 24 hours" }, { key: "7d", label: "Last 7 days" },
  { key: "30d", label: "Last 30 days" }, { key: "inactive90", label: "Not seen 90+ days" },
] as const;
const PLATFORM_OPTIONS = [
  { key: "", label: "All platforms" }, { key: "app", label: "App" }, { key: "web", label: "Website" }, { key: "unknown", label: "Unknown" },
] as const;
const SORT_OPTIONS: { key: MemberSort; label: string }[] = [
  { key: "joined_desc", label: "Newest members" }, { key: "joined_asc", label: "Oldest members" },
  { key: "active_desc", label: "Recently active" }, { key: "active_asc", label: "Longest inactive" },
  { key: "name_asc", label: "Name A–Z" }, { key: "name_desc", label: "Name Z–A" },
];
const OPTIONAL_COLUMNS = [
  { key: "roles", label: "Roles & badges" }, { key: "active", label: "Last active" }, { key: "joined", label: "Joined" },
] as const;
type ColumnKey = (typeof OPTIONAL_COLUMNS)[number]["key"];
const COLS_KEY = "admin-members-columns";
const ALL = "__all";

function loadColumns(): Set<ColumnKey> {
  try {
    const raw = localStorage.getItem(COLS_KEY);
    if (raw) return new Set(JSON.parse(raw) as ColumnKey[]);
  } catch { /* private mode */ }
  return new Set(OPTIONAL_COLUMNS.map((c) => c.key));
}

const PlatformLine = ({ p, m }: { p: AdminMember["last_platform"]; m: AdminMember }) =>
  p === "app" ? <span className="inline-flex items-center gap-1 text-[11px] text-muted-foreground"><Smartphone className="h-3 w-3" />{appLabel(m)}</span>
  : p === "web" ? <span className="inline-flex items-center gap-1 text-[11px] text-muted-foreground"><Globe className="h-3 w-3" />Website</span>
  : <span className="text-[11px] text-muted-foreground/70" title="No app or website session recorded yet">Platform unknown</span>;

/** When they were last here, and from where (app / website). */
const ActiveCell = ({ m, online }: { m: AdminMember; online: boolean }) => (
  <div>
    {online
      ? <span className="inline-flex items-center gap-1.5 text-sm font-medium text-emerald-600"><span className="h-2 w-2 animate-pulse rounded-full bg-emerald-500" />Active now</span>
      : <span className="text-sm whitespace-nowrap" title={formatLastSeen(m.last_active_at) || undefined}>{istDateTime(m.last_active_at) || "Never"}</span>}
    <div><PlatformLine p={m.last_platform} m={m} /></div>
    {m.last_sign_in_at && <div className="whitespace-nowrap text-[11px] text-muted-foreground">Last login {istDateTime(m.last_sign_in_at)}</div>}
  </div>
);

/** The ⋯ menu — the same list on a table row and on a phone card. */
function RowMenu({ m, open, actions }: { m: AdminMember; open: (m: AdminMember) => void; actions: MemberActions }) {
  const href = memberPath(m.custom_url);
  const restricted = m.status === "suspended" || m.status === "banned";
  const reviewed = m.status === "under_review" || m.status === "deletion_requested";
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" className="h-9 w-9" aria-label={`Actions for ${m.full_name ?? "member"}`} data-testid="member-row-menu" onClick={(e) => e.stopPropagation()}>
          <MoreHorizontal className="h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-56" onClick={(e) => e.stopPropagation()}>
        <DropdownMenuLabel className="truncate">{m.full_name || m.email}</DropdownMenuLabel>
        <DropdownMenuItem onSelect={() => open(m)}><UserCog className="mr-2 h-4 w-4" />Open details, roles & badges</DropdownMenuItem>
        {href && <DropdownMenuItem asChild><a href={href} target="_blank" rel="noopener noreferrer"><ExternalLink className="mr-2 h-4 w-4" />View profile</a></DropdownMenuItem>}
        <DropdownMenuSeparator />
        {restricted
          ? <DropdownMenuItem onSelect={() => actions.lift(m)}><ShieldCheck className="mr-2 h-4 w-4" />Lift suspension</DropdownMenuItem>
          : <DropdownMenuItem onSelect={() => actions.suspend([m])}><Ban className="mr-2 h-4 w-4" />Suspend…</DropdownMenuItem>}
        {reviewed
          ? <DropdownMenuItem onSelect={() => actions.account("active", [m])}><UserCheck className="mr-2 h-4 w-4" />Make active</DropdownMenuItem>
          : <DropdownMenuItem onSelect={() => actions.account("under_review", [m])}><ShieldAlert className="mr-2 h-4 w-4" />Put under review…</DropdownMenuItem>}
        {m.status === "deletion_requested" && (
          <>
            <DropdownMenuItem onSelect={() => actions.account("approve", [m])}><CheckCircle2 className="mr-2 h-4 w-4" />Approve deletion…</DropdownMenuItem>
            <DropdownMenuItem onSelect={() => actions.account("hold", [m])}><PauseCircle className="mr-2 h-4 w-4" />Hold deletion…</DropdownMenuItem>
          </>
        )}
        <DropdownMenuSeparator />
        <DropdownMenuItem className="text-destructive focus:text-destructive" onSelect={() => actions.account("delete", [m])}>
          <Trash2 className="mr-2 h-4 w-4" />Delete member…
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function SortHead({ label, asc, desc, sort, onSort, className }: { label: string; asc: MemberSort; desc: MemberSort; sort: MemberSort; onSort: (s: MemberSort) => void; className?: string }) {
  const Icon = sort === asc ? ChevronUp : sort === desc ? ChevronDown : ChevronsUpDown;
  return (
    <TableHead className={className} aria-sort={sort === asc ? "ascending" : sort === desc ? "descending" : "none"}>
      <button type="button" className="inline-flex items-center gap-1 hover:text-foreground" onClick={() => onSort(sort === desc ? asc : desc)}>
        {label}<Icon className="h-3.5 w-3.5" />
      </button>
    </TableHead>
  );
}

/** Suspend one or several members: for N days or until lifted, with a reason. */
function SuspendDialog({ targets, onClose, onConfirm }: { targets: AdminMember[]; onClose: () => void; onConfirm: (days: number | null, reason: string) => Promise<void> }) {
  const [mode, setMode] = useState<"days" | "until_lifted">("days");
  const [days, setDays] = useState("7");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const who = targets.length === 1 ? (targets[0].full_name || targets[0].email || "this member") : `${targets.length} members`;
  const validDays = Number(days) >= 1;
  return (
    <Dialog open={targets.length > 0} onOpenChange={(o) => { if (!o && !busy) onClose(); }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Suspend {who}</DialogTitle>
          <DialogDescription>A suspended member can sign in and look, but cannot post, comment, like or message.</DialogDescription>
        </DialogHeader>
        <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="How long">
          {(["days", "until_lifted"] as const).map((k) => (
            <button key={k} type="button" role="radio" aria-checked={mode === k} onClick={() => setMode(k)}
              className={cn("min-h-10 rounded-md border px-3 text-sm", mode === k ? "border-primary bg-primary/10 text-foreground" : "border-border text-muted-foreground")}>
              {k === "days" ? "For some days" : "Until I lift it"}
            </button>
          ))}
        </div>
        {mode === "days" && (
          <label className="flex items-center gap-2 text-sm">
            <Input type="number" min={1} value={days} onChange={(e) => setDays(e.target.value)} className="w-24" aria-label="Days" /> days
          </label>
        )}
        <label className="space-y-1 text-sm">
          <span className="font-medium">Reason</span>
          <Textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={2} maxLength={500} placeholder="Shown to the member" />
        </label>
        <DialogFooter>
          <Button variant="outline" disabled={busy} onClick={onClose}>Cancel</Button>
          <Button variant="destructive" disabled={busy || (mode === "days" && !validDays)} onClick={async () => {
            setBusy(true);
            await onConfirm(mode === "days" ? Number(days) : null, reason);
            setBusy(false);
          }}>
            {busy && <Loader2 className="mr-1 h-4 w-4 animate-spin" />}Suspend
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export default function AdminMembersTable({ user }: { user: AuthUser | null }) {
  const isPhone = useIsMobile();
  const online = useOnlineIds();
  const labels = useMemberLabels();
  const qc = useQueryClient();
  const writes = useMemberWrites(user?.id ?? null);
  const { confirm, dialogProps } = useConfirmAction();

  const [f, setF] = useState<MemberFilters>(DEFAULT_MEMBER_FILTERS);
  const [searchText, setSearchText] = useState("");
  const [selected, setSelected] = useState<Map<string, AdminMember>>(new Map());
  const [openId, setOpenId] = useState<string | null>(null);
  const [suspendTargets, setSuspendTargets] = useState<AdminMember[]>([]);
  const [pendingAccount, setPendingAccount] = useState<PendingAccountAction | null>(null);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [cols, setCols] = useState<Set<ColumnKey>>(loadColumns);
  const searchRef = useRef<HTMLInputElement>(null);

  const { data, isFetching, error, isLoading } = useAdminMembers(f);
  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const facets = data?.facets ?? null;
  const pageCount = Math.max(1, Math.ceil(total / f.pageSize));
  const openMember = rows.find((r) => r.id === openId) ?? null;

  const set = (patch: Partial<MemberFilters>) => setF((prev) => ({ ...prev, page: 0, ...patch }));

  // Search as you type, 300 ms after the last key.
  useEffect(() => {
    const t = setTimeout(() => { if (searchText.trim() !== f.query) set({ query: searchText.trim() }); }, 300);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps

  // "/" jumps to the search box.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement | null)?.tagName;
      if (e.key === "/" && tag !== "INPUT" && tag !== "TEXTAREA") { e.preventDefault(); searchRef.current?.focus(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // Live: a profile change (sign-in, suspension, ban, name) repaints the page
  // being looked at. Role and badge changes made here refresh the table
  // themselves (useMemberWrites); ones made elsewhere show on the next
  // refetch — no unfiltered feed of user_roles / user_badges (audit-v6 0B-4).
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    const refresh = () => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => void qc.invalidateQueries({ queryKey: queryKeys.adminMembers() }), 400);
    };
    const channel = supabase
      .channel("admin-members-live")
      .on("postgres_changes", { event: "*", schema: "public", table: "profiles" }, refresh)
      .subscribe();
    return () => { if (timer) clearTimeout(timer); void supabase.removeChannel(channel); };
  }, [qc]);

  const toggleCol = (k: ColumnKey) => setCols((prev) => {
    const next = new Set(prev);
    if (next.has(k)) next.delete(k); else next.add(k);
    try { localStorage.setItem(COLS_KEY, JSON.stringify([...next])); } catch { /* private mode */ }
    return next;
  });

  const toggleRow = (m: AdminMember) => setSelected((prev) => {
    const next = new Map(prev);
    if (next.has(m.id)) next.delete(m.id); else next.set(m.id, m);
    return next;
  });
  const pageAllSelected = rows.length > 0 && rows.every((r) => selected.has(r.id));
  const pageSomeSelected = rows.some((r) => selected.has(r.id));
  const togglePage = () => setSelected((prev) => {
    const next = new Map(prev);
    if (pageAllSelected) rows.forEach((r) => next.delete(r.id)); else rows.forEach((r) => next.set(r.id, r));
    return next;
  });

  const report = (err: string | null, ok: string): void => { toast(err ? { title: "Not done", description: err, variant: "destructive" } : { title: ok }); };

  const actions: MemberActions = {
    setRole: (m, role, on) => {
      const run = async () => report(await writes.setRole(m.id, role, on), `${labels.role(role).label} ${on ? "added" : "removed"}`);
      if (on) void run(); else confirm({ title: `Remove "${labels.role(role).label}" from ${m.full_name ?? "this member"}?`, onConfirm: run });
    },
    setBadge: (m, badge, on) => {
      const run = async () => report(await writes.setBadge(m.id, badge, on), `${labels.badge(badge).label} ${on ? "added" : "removed"}`);
      if (on) void run(); else confirm({ title: `Remove the "${labels.badge(badge).label}" badge?`, onConfirm: run });
    },
    saveProfile: (m, name, bio) => writes.saveProfile(m.id, name, bio),
    suspend: (ms) => setSuspendTargets(ms),
    lift: (m) => confirm({
      title: `Lift the suspension of ${m.full_name ?? "this member"}?`,
      description: m.status === "banned" ? "This member is also banned; lifting the suspension does not lift the ban." : undefined,
      onConfirm: async () => report(await writes.liftSuspension(m.id), "Suspension lifted"),
    }),
    account: (kind, ms) => setPendingAccount({
      kind, userIds: ms.map((m) => m.id),
      name: ms.length === 1 ? (ms[0].full_name || ms[0].email || "This member") : `${ms.length} members`,
    }),
  };

  const bulkRole = (role: string, on: boolean) => {
    const targets = [...selected.values()].filter((m) => m.roles.includes(role) !== on);
    const run = async () => {
      let ok = 0;
      for (const m of targets) if (!(await writes.setRole(m.id, role, on))) ok++;
      toast({ title: `${labels.role(role).label} ${on ? "added to" : "removed from"} ${ok} member${ok === 1 ? "" : "s"}` });
      setSelected(new Map());
    };
    if (!targets.length) { toast({ title: `Nobody selected ${on ? "lacks" : "has"} that role` }); return; }
    if (on) void run(); else confirm({ title: `Remove "${labels.role(role).label}" from ${targets.length} member(s)?`, onConfirm: run });
  };

  if (error instanceof MembersRpcMissing) {
    return <Suspense fallback={<Loader2 className="mx-auto h-5 w-5 animate-spin" />}><AdminUsersPrevious user={user} /></Suspense>;
  }

  const attention = facets ? facets.status.suspended + facets.status.banned + facets.status.under_review + facets.status.deletion_requested : 0;
  const activeFilterCount = [f.role, f.badge, f.platform, f.active].filter(Boolean).length;
  const from = total === 0 ? 0 : f.page * f.pageSize + 1;
  const to = Math.min(total, (f.page + 1) * f.pageSize);

  const filterSelects = (
    <>
      <Select value={f.role || ALL} onValueChange={(v) => set({ role: v === ALL ? "" : v })}>
        <SelectTrigger className="h-9 w-full md:w-[136px]" aria-label="Role"><SelectValue placeholder="Role" /></SelectTrigger>
        <SelectContent>
          <SelectItem value={ALL}>All roles</SelectItem>
          {labels.allRoles.filter((r) => r !== "user").map((r) => <SelectItem key={r} value={r}>{labels.role(r).icon} {labels.role(r).label}</SelectItem>)}
        </SelectContent>
      </Select>
      {labels.allBadges.length > 0 && (
        <Select value={f.badge || ALL} onValueChange={(v) => set({ badge: v === ALL ? "" : v })}>
          <SelectTrigger className="h-9 w-full md:w-[136px]" aria-label="Badge"><SelectValue placeholder="Badge" /></SelectTrigger>
          <SelectContent>
            <SelectItem value={ALL}>All badges</SelectItem>
            {labels.allBadges.map((b) => <SelectItem key={b} value={b}>{labels.badge(b).icon} {labels.badge(b).label}</SelectItem>)}
          </SelectContent>
        </Select>
      )}
      <Select value={f.platform || ALL} onValueChange={(v) => set({ platform: (v === ALL ? "" : v) as MemberFilters["platform"] })}>
        <SelectTrigger className="h-9 w-full md:w-[150px]" aria-label="Platform"><SelectValue placeholder="Platform" /></SelectTrigger>
        <SelectContent>
          {PLATFORM_OPTIONS.map((p) => {
            const c = facets ? facets.platform[(p.key || "all") as keyof typeof facets.platform] : null;
            return <SelectItem key={p.key || ALL} value={p.key || ALL}>{p.label}{c !== null && p.key ? ` (${c.toLocaleString()})` : ""}</SelectItem>;
          })}
        </SelectContent>
      </Select>
      <Select value={f.active || ALL} onValueChange={(v) => set({ active: (v === ALL ? "" : v) as MemberFilters["active"] })}>
        <SelectTrigger className="h-9 w-full md:w-[150px]" aria-label="Last active"><SelectValue placeholder="Last active" /></SelectTrigger>
        <SelectContent>{ACTIVE_OPTIONS.map((a) => <SelectItem key={a.key || ALL} value={a.key || ALL}>{a.label}</SelectItem>)}</SelectContent>
      </Select>
    </>
  );

  return (
    <div className="space-y-4 pb-24" data-testid="admin-members">
      {/* Heading */}
      <div className="flex flex-wrap items-end justify-between gap-2 px-1">
        <div>
          <h2 className="text-lg font-semibold">Members</h2>
          <p className="text-xs text-muted-foreground">
            {facets ? facets.status.all.toLocaleString() : "…"} members
            {attention > 0 && <> · <button type="button" className="text-amber-600 hover:underline" onClick={() => set({ status: "suspended" })}>{attention} need attention</button></>}
          </p>
        </div>
        {!isPhone && (
          <DropdownMenu modal={false}>
            <DropdownMenuTrigger asChild><Button variant="outline" size="sm"><Columns3 className="mr-1 h-4 w-4" />Columns</Button></DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              {OPTIONAL_COLUMNS.map((c) => (
                <DropdownMenuCheckboxItem key={c.key} checked={cols.has(c.key)} onCheckedChange={() => toggleCol(c.key)} onSelect={(e) => e.preventDefault()}>{c.label}</DropdownMenuCheckboxItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>

      {/* Status tabs */}
      <div className="-mx-1 flex gap-1.5 overflow-x-auto px-1 pb-1" role="tablist" aria-label="Status">
        {STATUS_TABS.map((t) => {
          const count = facets ? facets.status[(t.key || "all") as keyof typeof facets.status] : null;
          const on = f.status === t.key;
          return (
            <button key={t.key || "all"} type="button" role="tab" aria-selected={on} data-testid={`status-tab-${t.key || "all"}`}
              onClick={() => set({ status: t.key })}
              className={cn("inline-flex min-h-9 shrink-0 items-center gap-2 rounded-full border px-3 text-sm transition-colors",
                on ? "border-primary bg-primary text-primary-foreground" : "border-border bg-card hover:border-primary/60")}>
              {t.key && <span className={cn("h-2 w-2 rounded-full", STATUS_META[t.key].dot)} aria-hidden />}
              {t.label}
              {count !== null && (
                <span className={cn("rounded-full px-1.5 text-xs tabular-nums", on ? "bg-primary-foreground/20" : "bg-muted text-muted-foreground",
                  !on && t.key && t.key !== "active" && count > 0 && "bg-amber-500/15 text-amber-700 dark:text-amber-300")}>
                  {count.toLocaleString()}
                </span>
              )}
            </button>
          );
        })}
      </div>

      {/* Search + filters */}
      <div className="flex flex-col gap-2 md:flex-row md:flex-wrap md:items-center">
        <div className="relative min-w-0 flex-1 md:min-w-[220px]">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input ref={searchRef} value={searchText} onChange={(e) => setSearchText(e.target.value)} placeholder="Search name, e-mail or @handle" className="h-9 pl-9 pr-16" aria-label="Search members" />
          {searchText ? (
            <button type="button" className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-muted-foreground hover:text-foreground" aria-label="Clear search" onClick={() => setSearchText("")}><X className="h-4 w-4" /></button>
          ) : !isPhone && (
            <kbd className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 rounded border border-border px-1.5 text-[10px] text-muted-foreground">/</kbd>
          )}
        </div>
        {isPhone ? (
          <div className="flex gap-2">
            <Button variant="outline" size="sm" className="h-9 flex-1" onClick={() => setFiltersOpen(true)} data-testid="members-filters-open">
              <SlidersHorizontal className="mr-1 h-4 w-4" />Filters{activeFilterCount ? ` (${activeFilterCount})` : ""}
            </Button>
            <Select value={f.sort} onValueChange={(v) => set({ sort: v as MemberSort })}>
              <SelectTrigger className="h-9 flex-1" aria-label="Sort"><SelectValue /></SelectTrigger>
              <SelectContent>{SORT_OPTIONS.map((s) => <SelectItem key={s.key} value={s.key}>{s.label}</SelectItem>)}</SelectContent>
            </Select>
          </div>
        ) : (
          <div className="flex flex-wrap items-center gap-2">
            {filterSelects}
            {(activeFilterCount > 0 || f.query) && (
              <Button variant="ghost" size="sm" className="h-9" onClick={() => { setSearchText(""); setF({ ...DEFAULT_MEMBER_FILTERS, pageSize: f.pageSize, sort: f.sort, status: f.status }); }}>
                <X className="mr-1 h-4 w-4" />Clear
              </Button>
            )}
          </div>
        )}
      </div>

      {/* Rows */}
      {isLoading ? (
        <div className="flex justify-center py-16"><Loader2 className="h-5 w-5 animate-spin text-muted-foreground" /></div>
      ) : error ? (
        <p className="rounded-lg border border-destructive/40 p-4 text-sm text-destructive">Could not load members: {(error as Error).message}</p>
      ) : rows.length === 0 ? (
        <div className="rounded-xl border border-dashed border-border py-14 text-center text-sm text-muted-foreground">
          No members match{f.status ? ` "${STATUS_META[f.status].label}"` : ""}{f.query ? ` "${f.query}"` : ""}.
        </div>
      ) : isPhone ? (
        <ul className={cn("space-y-2 transition-opacity", isFetching && "opacity-60")}>
          {rows.map((m) => (
            <li key={m.id} data-testid="member-row" className={cn("rounded-xl border bg-card p-3", selected.has(m.id) ? "border-primary" : "border-border")}>
              <div className="flex items-start gap-3">
                <Checkbox checked={selected.has(m.id)} onCheckedChange={() => toggleRow(m)} aria-label={`Select ${m.full_name ?? "member"}`} className="mt-2.5" data-testid="member-row-select" />
                <button type="button" className="flex min-w-0 flex-1 items-start gap-3 text-left" onClick={() => setOpenId(m.id)} data-testid="member-open">
                  <span className="relative">
                    <MemberAvatar m={m} size={40} />
                    {online.has(m.id) && <span className="absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full border-2 border-card bg-emerald-500" />}
                  </span>
                  <span className="min-w-0 flex-1 space-y-1">
                    <span className="flex items-center gap-2">
                      <span className="truncate font-medium">{m.full_name || "No name"}</span>
                    </span>
                    <span className="block truncate text-xs text-muted-foreground">{m.email ?? "—"}</span>
                    <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
                      <StatusChip status={m.status} />
                      <span className="whitespace-nowrap">
                        {m.last_platform === "app" ? appLabel(m) : m.last_platform === "web" ? "Website" : "Unknown"} ·{" "}
                        <span className={online.has(m.id) ? "text-emerald-600" : undefined}>{online.has(m.id) ? "Active now" : istDateTime(m.last_active_at) || "Never"}</span>
                      </span>
                      {m.last_sign_in_at && <span className="block whitespace-nowrap">Last login {istDateTime(m.last_sign_in_at)}</span>}
                    </span>
                    {(m.roles.some((r) => r !== "user") || m.badges.length > 0) && <RolePills m={m} labels={labels} max={3} />}
                  </span>
                </button>
                <RowMenu m={m} open={(x) => setOpenId(x.id)} actions={actions} />
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <div className={cn("overflow-x-auto rounded-xl border border-border bg-card transition-opacity", isFetching && "opacity-60")}>
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead className="w-10">
                  <Checkbox checked={pageAllSelected ? true : pageSomeSelected ? "indeterminate" : false} onCheckedChange={togglePage} aria-label="Select this page" />
                </TableHead>
                <SortHead label="Member" asc="name_asc" desc="name_desc" sort={f.sort} onSort={(s) => set({ sort: s })} />
                <TableHead>Status</TableHead>
                {cols.has("roles") && <TableHead>Roles &amp; badges</TableHead>}
                {cols.has("active") && <SortHead label="Last active" asc="active_asc" desc="active_desc" sort={f.sort} onSort={(s) => set({ sort: s })} />}
                {cols.has("joined") && <SortHead label="Joined" asc="joined_asc" desc="joined_desc" sort={f.sort} onSort={(s) => set({ sort: s })} />}
                <TableHead className="w-12"><span className="sr-only">Actions</span></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((m) => {
                const detail = statusDetail(m);
                return (
                  <TableRow key={m.id} data-testid="member-row" data-state={selected.has(m.id) ? "selected" : undefined}
                    className={cn("cursor-pointer data-[state=selected]:bg-primary/10", m.status === "banned" && "bg-red-500/[0.04]", m.status === "suspended" && "bg-amber-500/[0.04]")}
                    onClick={() => setOpenId(m.id)}>
                    <TableCell onClick={(e) => e.stopPropagation()}>
                      <Checkbox checked={selected.has(m.id)} onCheckedChange={() => toggleRow(m)} aria-label={`Select ${m.full_name ?? "member"}`} data-testid="member-row-select" />
                    </TableCell>
                    <TableCell className="max-w-[300px]">
                      <div className="flex items-center gap-3">
                        <span className="relative">
                          <MemberAvatar m={m} />
                          {online.has(m.id) && <span className="absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full border-2 border-card bg-emerald-500" />}
                        </span>
                        <div className="min-w-0">
                          <button type="button" className="block max-w-full truncate text-left font-medium hover:underline" data-testid="member-open" onClick={(e) => { e.stopPropagation(); setOpenId(m.id); }}>
                            {m.full_name || "No name"}
                          </button>
                          <div className="truncate text-xs text-muted-foreground">{m.email ?? "—"}{m.custom_url ? ` · @${m.custom_url}` : ""}</div>
                        </div>
                      </div>
                    </TableCell>
                    <TableCell>
                      <StatusChip status={m.status} />
                      {detail && <div className="mt-0.5 text-[11px] text-muted-foreground">{detail}</div>}
                    </TableCell>
                    {cols.has("roles") && <TableCell className="max-w-[220px]"><RolePills m={m} labels={labels} max={2} /></TableCell>}
                    {cols.has("active") && <TableCell className="whitespace-nowrap"><ActiveCell m={m} online={online.has(m.id)} /></TableCell>}
                    {cols.has("joined") && <TableCell className="whitespace-nowrap text-sm text-muted-foreground">{istDateTime(m.created_at) ?? fmtDate(m.created_at)}</TableCell>}
                    <TableCell onClick={(e) => e.stopPropagation()}><RowMenu m={m} open={(x) => setOpenId(x.id)} actions={actions} /></TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      {/* Pager */}
      {total > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-3 px-1 text-sm">
          <div className="flex items-center gap-2 text-muted-foreground">
            <span className="hidden sm:inline">Rows per page</span>
            <Select value={String(f.pageSize)} onValueChange={(v) => set({ pageSize: Number(v) })}>
              <SelectTrigger className="h-8 w-[72px]" aria-label="Rows per page"><SelectValue /></SelectTrigger>
              <SelectContent>{[25, 50, 100].map((s) => <SelectItem key={s} value={String(s)}>{s}</SelectItem>)}</SelectContent>
            </Select>
          </div>
          <div className="flex items-center gap-3">
            <span className="tabular-nums text-muted-foreground" data-testid="members-range">{from.toLocaleString()}–{to.toLocaleString()} of {total.toLocaleString()}</span>
            <div className="flex items-center gap-1">
              <Button variant="outline" size="icon" className="h-9 w-9" disabled={f.page === 0} aria-label="Previous page" onClick={() => setF((p) => ({ ...p, page: p.page - 1 }))}><ChevronLeft className="h-4 w-4" /></Button>
              <span className="min-w-[72px] text-center tabular-nums">Page {f.page + 1} / {pageCount.toLocaleString()}</span>
              <Button variant="outline" size="icon" className="h-9 w-9" disabled={f.page >= pageCount - 1} aria-label="Next page" onClick={() => setF((p) => ({ ...p, page: p.page + 1 }))}><ChevronRight className="h-4 w-4" /></Button>
            </div>
          </div>
        </div>
      )}

      {/* Bulk bar */}
      {selected.size > 0 && (
        <div className="fixed inset-x-3 bottom-4 z-40 mx-auto flex max-w-3xl flex-wrap items-center gap-2 rounded-xl border border-border bg-popover p-2 pl-4 shadow-2xl" role="toolbar" aria-label="Selected members" data-testid="members-bulk-bar">
          <span className="mr-1 text-sm font-medium">{selected.size} selected</span>
          <DropdownMenu modal={false}>
            <DropdownMenuTrigger asChild><Button size="sm" variant="outline"><Plus className="mr-1 h-4 w-4" />Add role</Button></DropdownMenuTrigger>
            <DropdownMenuContent>{labels.allRoles.filter((r) => r !== "user").map((r) => <DropdownMenuItem key={r} onSelect={() => bulkRole(r, true)}>{labels.role(r).icon} {labels.role(r).label}</DropdownMenuItem>)}</DropdownMenuContent>
          </DropdownMenu>
          <DropdownMenu modal={false}>
            <DropdownMenuTrigger asChild><Button size="sm" variant="outline"><Minus className="mr-1 h-4 w-4" />Remove role</Button></DropdownMenuTrigger>
            <DropdownMenuContent>{labels.allRoles.filter((r) => r !== "user").map((r) => <DropdownMenuItem key={r} onSelect={() => bulkRole(r, false)}>{labels.role(r).icon} {labels.role(r).label}</DropdownMenuItem>)}</DropdownMenuContent>
          </DropdownMenu>
          <Button size="sm" variant="outline" onClick={() => actions.suspend([...selected.values()])}><Ban className="mr-1 h-4 w-4" />Suspend…</Button>
          <Button size="sm" variant="outline" onClick={() => actions.account("under_review", [...selected.values()])}><ShieldAlert className="mr-1 h-4 w-4" />Under review…</Button>
          <Button size="sm" variant="ghost" className="ml-auto" onClick={() => setSelected(new Map())} aria-label="Clear selection"><X className="h-4 w-4" /></Button>
        </div>
      )}

      {/* Phone filters */}
      <Sheet open={filtersOpen} onOpenChange={setFiltersOpen}>
        <SheetContent side="bottom" className="space-y-3 rounded-t-2xl" data-testid="members-filters-sheet">
          <SheetHeader><SheetTitle>Filters</SheetTitle></SheetHeader>
          <div className="grid gap-2">{filterSelects}</div>
          <div className="flex gap-2 pt-2">
            <Button variant="outline" className="flex-1" onClick={() => set({ role: "", badge: "", platform: "", active: "" })}>Clear</Button>
            <Button className="flex-1" onClick={() => setFiltersOpen(false)}>Show {total.toLocaleString()} members</Button>
          </div>
        </SheetContent>
      </Sheet>

      <MemberDrawer member={openMember} online={!!openMember && online.has(openMember.id)} labels={labels} actions={actions} onClose={() => setOpenId(null)} />
      <SuspendDialog
        targets={suspendTargets}
        onClose={() => setSuspendTargets([])}
        onConfirm={async (days, reason) => {
          let ok = 0;
          let lastErr: string | null = null;
          for (const m of suspendTargets) { const e = await writes.suspend(m.id, days, reason); if (e) lastErr = e; else ok++; }
          report(ok ? null : lastErr, `Suspended ${ok} member${ok === 1 ? "" : "s"}`);
          setSuspendTargets([]);
          setSelected(new Map());
        }}
      />
      <AccountActionDialog
        pending={pendingAccount}
        onClose={() => setPendingAccount(null)}
        onDone={() => { setSelected(new Map()); void writes.refresh(); }}
      />
      <ConfirmDialog {...dialogProps} />
    </div>
  );
}

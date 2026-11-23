/**
 * Admin → Users: which app each member uses (SQL 4400 / M34, Owner 2026-11-23).
 * One copy of each piece — the App line (table column, phone card, drawer),
 * the versions card at the top of the page and the member list behind a card
 * row. Data: useAppVersions. Same tokens as the members table: muted text,
 * amber for "needs attention" (an old build), emerald for the latest.
 */
import { useState, type SVGProps } from "react";
import { Apple, BellOff, ChevronLeft, ChevronRight, ExternalLink, Globe, History, Loader2, Smartphone } from "lucide-react";
import { cn } from "@/lib/utils";
import { memberPath } from "@/lib/urlHelpers";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import {
  useAppVersionMembers, VERSION_MEMBERS_PAGE,
  type AppGroup, type AppLine, type AppOs, type AppVersionSummary, type VersionRow,
} from "@/hooks/admin/useAppVersions";
import { isOldVersion } from "@/lib/versionCompare";
import { MemberAvatar } from "./memberUi";

/** The Android head, drawn like a lucide icon (lucide has no Android mark). */
export function AndroidIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden {...props}>
      <path d="M4.5 17a7.5 7.5 0 0 1 15 0Z" />
      <path d="M7.5 10.5 5.5 7.5M16.5 10.5l2-3" />
      <circle cx="9.25" cy="13.6" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="14.75" cy="13.6" r="0.6" fill="currentColor" stroke="none" />
    </svg>
  );
}

export const OS_LABEL: Record<AppOs, string> = { android: "Android", ios: "iPhone" };
export const OsIcon = ({ os, className }: { os: AppOs | null; className?: string }) =>
  os === "ios" ? <Apple className={className} aria-hidden /> : os === "android" ? <AndroidIcon className={className} /> : <Smartphone className={className} aria-hidden />;

/** "just now" · "12m ago" · "3h ago" · "4d ago" · "3w ago" · "12 Aug 2026". */
export function openedAgo(iso: string | null): string {
  if (!iso) return "";
  const mins = Math.floor((Date.now() - Date.parse(iso)) / 60_000);
  if (!Number.isFinite(mins)) return "";
  if (mins < 2) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  if (days < 14) return `${days}d ago`;
  if (days < 60) return `${Math.floor(days / 7)}w ago`;
  return new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}

const CHIP = "inline-flex items-center rounded-full border px-1.5 text-[10px] font-medium leading-4";
export const LatestChip = () => <span className={cn(CHIP, "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300")}>Latest</span>;
export const OldChip = () => <span className={cn(CHIP, "border-amber-500/40 bg-amber-500/10 text-amber-700 dark:text-amber-300")}>Old</span>;

/**
 * One member's app, two lines: "[icon] 1.2.56 Latest" / "Android · opened 2h ago".
 * `inline` = one short line for the phone card.
 */
export function AppLineView({ line, inline = false }: { line: AppLine; inline?: boolean }) {
  if (line.kind === "none") return <span className="text-xs text-muted-foreground/70" title="No app or website session recorded yet">—</span>;
  if (line.kind === "web") {
    return <span className="inline-flex items-center gap-1 whitespace-nowrap text-xs text-muted-foreground"><Globe className="h-3.5 w-3.5" />Website</span>;
  }
  const seen = openedAgo(line.seenAt);
  if (line.kind === "older") {
    const head = (
      <span className="inline-flex items-center gap-1 whitespace-nowrap text-xs font-medium text-amber-700 dark:text-amber-300" data-testid="app-older">
        <OsIcon os={line.os} className="h-3.5 w-3.5" />Older app
      </span>
    );
    if (inline) return head;
    return (
      <div>
        {head}
        <div className="whitespace-nowrap text-[11px] text-muted-foreground">No version{seen ? ` · ${seen}` : ""}</div>
      </div>
    );
  }
  const head = (
    <span className="inline-flex items-center gap-1 whitespace-nowrap text-xs" data-testid={`app-${line.os}`}>
      <OsIcon os={line.os} className={cn("h-3.5 w-3.5", line.old ? "text-amber-600 dark:text-amber-400" : "text-muted-foreground")} />
      {inline && <span className="text-muted-foreground">{OS_LABEL[line.os]}</span>}
      <span className={cn("font-medium tabular-nums", line.old && "text-amber-700 dark:text-amber-300")}>{line.version}</span>
      {line.old ? <OldChip /> : line.latest ? <LatestChip /> : null}
    </span>
  );
  if (inline) return head;
  return (
    <div>
      {head}
      <div className="flex items-center gap-1 whitespace-nowrap text-[11px] text-muted-foreground">
        {OS_LABEL[line.os]}{seen ? ` · ${seen}` : ""}
        {line.push === "off" && <BellOff className="h-3 w-3" aria-label="Notifications off" />}
      </div>
    </div>
  );
}

/** The drawer's sentence for the same line. */
export function appLineText(line: AppLine): string {
  if (line.kind === "none") return "Nothing recorded";
  if (line.kind === "web") return "Website only";
  const seen = openedAgo(line.seenAt);
  if (line.kind === "older") return `Older app, no version recorded${seen ? ` · opened ${seen}` : ""}`;
  return `${OS_LABEL[line.os]} ${line.version}${seen ? ` · opened ${seen}` : ""}`;
}

// ── the versions card ────────────────────────────────────────────────────────

const SHOW = 4;

function VersionList({ os, rows, newest, onOpen }: { os: AppOs; rows: VersionRow[]; newest: string | null; onOpen: (g: AppGroup) => void }) {
  const [all, setAll] = useState(false);
  const max = Math.max(1, ...rows.map((r) => r.members));
  const total = rows.reduce((s, r) => s + r.members, 0);
  const shown = all ? rows : rows.slice(0, SHOW);
  return (
    <div className="min-w-0 space-y-1" data-testid={`versions-${os}`}>
      <div className="flex items-center gap-1.5 px-2 text-xs font-medium text-muted-foreground">
        <OsIcon os={os} className="h-3.5 w-3.5" />{OS_LABEL[os]}
        <span className="tabular-nums">· {total.toLocaleString()}</span>
      </div>
      {rows.length === 0 ? (
        <p className="px-2 py-1.5 text-xs text-muted-foreground">No {OS_LABEL[os]} app reported yet.</p>
      ) : (
        <ul>
          {shown.map((r) => {
            const old = isOldVersion(r.version, newest);
            return (
              <li key={r.version}>
                <button type="button" onClick={() => onOpen({ os, version: r.version })} data-testid="version-row"
                  className="grid w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 rounded-md px-2 py-1.5 text-left hover:bg-muted/60 focus-visible:bg-muted/60 focus-visible:outline-none">
                  <span className="flex min-w-0 items-center gap-1.5">
                    <span className={cn("text-sm font-medium tabular-nums", old && "text-amber-700 dark:text-amber-300")}>{r.version}</span>
                    {old ? <OldChip /> : <LatestChip />}
                  </span>
                  <span className="text-right text-sm tabular-nums">
                    {r.members.toLocaleString()}
                    <span className="ml-1.5 text-[11px] text-muted-foreground">{r.active7d.toLocaleString()} this week</span>
                  </span>
                  <span className="col-span-2 mt-1 block h-1 overflow-hidden rounded-full bg-muted">
                    <span className={cn("block h-full rounded-full", old ? "bg-amber-500/60" : "bg-emerald-500/70")} style={{ width: `${Math.max(3, (r.members / max) * 100)}%` }} />
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {rows.length > SHOW && (
        <button type="button" className="px-2 text-xs text-primary hover:underline" onClick={() => setAll((v) => !v)}>
          {all ? "Show fewer" : `Show ${rows.length - SHOW} more`}
        </button>
      )}
    </div>
  );
}

/** "App versions" — Android and iPhone builds, newest first, plus older app / website only. */
export function AppVersionsCard({ summary, onOpen }: { summary: AppVersionSummary; onOpen: (g: AppGroup) => void }) {
  const oldCount = [...summary.android, ...summary.ios]
    .filter((r) => isOldVersion(r.version, summary.newest[r.os])).reduce((s, r) => s + r.members, 0) + summary.older.members;
  return (
    <section className="rounded-xl border border-border bg-card p-3 sm:p-4" aria-labelledby="app-versions-title" data-testid="app-versions-card">
      <div className="mb-2 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5 px-2">
        <h3 id="app-versions-title" className="text-sm font-semibold">App versions</h3>
        <p className="text-xs text-muted-foreground">
          {oldCount > 0 ? <span className="text-amber-700 dark:text-amber-300">{oldCount.toLocaleString()} on an old app</span> : "Everyone on the latest app"}
          {" · tap a row to see who"}
        </p>
      </div>
      <div className="grid gap-3 md:grid-cols-2 md:gap-6">
        <VersionList os="android" rows={summary.android} newest={summary.newest.android} onOpen={onOpen} />
        <VersionList os="ios" rows={summary.ios} newest={summary.newest.ios} onOpen={onOpen} />
      </div>
      <div className="mt-2 grid gap-1 border-t border-border pt-2 sm:grid-cols-2 sm:gap-6">
        <button type="button" onClick={() => onOpen({ os: "older" })} data-testid="version-row-older"
          className="flex items-center justify-between gap-3 rounded-md px-2 py-1.5 text-left hover:bg-muted/60">
          <span className="inline-flex min-w-0 items-center gap-1.5 text-sm text-amber-700 dark:text-amber-300">
            <History className="h-3.5 w-3.5 shrink-0" /><span className="truncate">Older app (no version)</span>
          </span>
          <span className="shrink-0 text-sm tabular-nums">
            {summary.older.members.toLocaleString()}
            <span className="ml-1.5 text-[11px] text-muted-foreground">{summary.older.active7d.toLocaleString()} this week</span>
          </span>
        </button>
        <button type="button" onClick={() => onOpen({ os: "web" })} data-testid="version-row-web"
          className="flex items-center justify-between gap-3 rounded-md px-2 py-1.5 text-left hover:bg-muted/60">
          <span className="inline-flex min-w-0 items-center gap-1.5 text-sm text-muted-foreground">
            <Globe className="h-3.5 w-3.5 shrink-0" /><span className="truncate">Website only</span>
          </span>
          <span className="shrink-0 text-sm tabular-nums">
            {summary.website.members.toLocaleString()}
            <span className="ml-1.5 text-[11px] text-muted-foreground">{summary.website.active7d.toLocaleString()} this week</span>
          </span>
        </button>
      </div>
      {summary.notRecorded > 0 && (
        <p className="mt-1 px-2 text-[11px] text-muted-foreground">{summary.notRecorded.toLocaleString()} members have no app or website session recorded.</p>
      )}
    </section>
  );
}

// ── the members behind one card row ─────────────────────────────────────────

const groupTitle = (g: AppGroup) =>
  g.os === "older" ? "Older app (no version)" : g.os === "web" ? "Website only" : `${OS_LABEL[g.os]} ${g.version}`;

export function AppVersionMembersDialog({ group, newest, onClose }: { group: AppGroup | null; newest: Record<AppOs, string | null>; onClose: () => void }) {
  const [page, setPage] = useState(0);
  const [shownFor, setShownFor] = useState<AppGroup | null>(group);
  if (group !== shownFor) { setShownFor(group); setPage(0); }
  const { data, isLoading, isFetching, error } = useAppVersionMembers(group, page);
  const total = data?.total ?? 0;
  const pages = Math.max(1, Math.ceil(total / VERSION_MEMBERS_PAGE));
  const old = !!group && "version" in group && isOldVersion(group.version, newest[group.os]);
  return (
    <Dialog open={!!group} onOpenChange={(o) => { if (!o) onClose(); }}>
      <DialogContent className="flex max-h-[85vh] flex-col gap-3 p-4 sm:max-w-lg sm:p-6" data-testid="app-version-members">
        {group && (
          <DialogHeader className="space-y-1 pr-6 text-left">
            <DialogTitle className="flex items-center gap-2 text-base">
              {group.os === "web" ? <Globe className="h-4 w-4" /> : group.os === "older" ? <History className="h-4 w-4 text-amber-600" /> : <OsIcon os={group.os} className="h-4 w-4" />}
              {groupTitle(group)}
              {"version" in group && (old ? <OldChip /> : <LatestChip />)}
            </DialogTitle>
            <DialogDescription>
              {isLoading ? "Loading…" : `${total.toLocaleString()} member${total === 1 ? "" : "s"}`}
              {group.os === "web" ? " · last signed in on the website, no app" : " · last opened the app, newest first"}
            </DialogDescription>
          </DialogHeader>
        )}
        <div className={cn("-mx-2 min-h-[120px] flex-1 overflow-y-auto", isFetching && !isLoading && "opacity-60")}>
          {isLoading ? (
            <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin text-muted-foreground" /></div>
          ) : error ? (
            <p className="px-2 py-6 text-sm text-destructive">Could not load: {(error as Error).message}</p>
          ) : !data?.rows.length ? (
            <p className="px-2 py-6 text-center text-sm text-muted-foreground">Nobody here.</p>
          ) : (
            <ul className="divide-y divide-border">
              {data.rows.map((m) => {
                const href = memberPath(m.custom_url);
                return (
                  <li key={m.id} className="flex items-center gap-3 px-2 py-2" data-testid="app-version-member">
                    <MemberAvatar m={{ avatar_url: m.avatar_url, full_name: m.full_name, email: null }} size={36} />
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-sm font-medium">{m.full_name || "No name"}</div>
                      <div className="truncate text-xs text-muted-foreground">
                        {m.custom_url ? `@${m.custom_url}` : "No handle"}
                        {group?.os === "older" && m.os ? ` · ${OS_LABEL[m.os]}` : ""}
                      </div>
                    </div>
                    <div className="shrink-0 text-right text-xs text-muted-foreground">
                      {group?.os === "web" ? "Signed in" : "Opened"}<br />
                      <span className="text-foreground">{openedAgo(m.seenAt) || "—"}</span>
                    </div>
                    {href && (
                      <a href={href} target="_blank" rel="noopener noreferrer" className="shrink-0 rounded p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground" aria-label={`Open ${m.full_name ?? "member"}'s profile`}>
                        <ExternalLink className="h-4 w-4" />
                      </a>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
        {pages > 1 && (
          <div className="flex items-center justify-end gap-1 text-sm">
            <Button variant="outline" size="icon" className="h-9 w-9" disabled={page === 0} aria-label="Previous page" onClick={() => setPage((p) => p - 1)}><ChevronLeft className="h-4 w-4" /></Button>
            <span className="min-w-[72px] text-center tabular-nums">Page {page + 1} / {pages}</span>
            <Button variant="outline" size="icon" className="h-9 w-9" disabled={page >= pages - 1} aria-label="Next page" onClick={() => setPage((p) => p + 1)}><ChevronRight className="h-4 w-4" /></Button>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

/**
 * M10/D · Admin → Messages → "Reports" on the ONE shared admin table: what members reported (the only queue
 * there is — there is no approval of ordinary messages), the closed ones, and the watch list (members reported
 * most in the last 30 days). No reason box: closing a report is one click, or tick several and close them together.
 * Click a report → side panel with the details and the chat itself, opened read only as the reporter sees it.
 */
import { useMemo, useState } from "react";
import { CheckCircle2, Download } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { toast } from "@/hooks/core/use-toast";
import AdminDataTable, { type DTColumn } from "@/components/admin/AdminDataTable";
import AdminSidePanel, { PanelField } from "@/components/admin/AdminSidePanel";
import { cmpDate, cmpNum, cmpText, downloadCsv, useClientTable } from "@/components/admin/useClientTable";
import { MemberAvatar } from "@/components/admin/users/memberUi";
import AutoBadge from "@/components/AutoBadge";
import MemberName from "@/components/MemberName";
import ChatPane from "@/components/messages/ChatPane";
import ExportChatButton from "./ExportChatButton";
import { ViewAsProvider } from "@/components/messages/viewAs";
import {
  adminMessageCall, useMessageReports, useMessageWatchlist, useRefreshAdminMessages, type ReportReasonKey, type ReportRow, type WatchRow,
} from "@/hooks/admin/useAdminMessages";

export const REASON_TEXT: Record<ReportReasonKey, string> = {
  spam: "Spam", abuse: "Abuse", threat: "Threats", nudity: "Nudity", other: "Other",
};
const when = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};
const who = (name: string | null, id: string | null) => name || (id ? id.slice(0, 8) : "a group chat");

type Tab = "open" | "done" | "watch";

export default function ReportsPanel() {
  const [tab, setTab] = useState<Tab>("open");
  const open = useMessageReports("open");
  const done = useMessageReports("done");
  const watch = useMessageWatchlist();
  const refresh = useRefreshAdminMessages();
  const [picked, setPicked] = useState<ReportRow | null>(null);
  const [busy, setBusy] = useState(false);

  const reportRows = useMemo(() => (tab === "done" ? done.data : open.data) ?? [], [tab, open.data, done.data]);
  const watchRows = useMemo(() => watch.data ?? [], [watch.data]);

  const closeMany = async (ids: number[]) => {
    setBusy(true);
    try {
      for (const id of ids) await adminMessageCall("admin_message_report_done", { _id: id, _note: null });
      toast({ title: "Done", description: ids.length === 1 ? "Report closed" : `${ids.length} reports closed` });
      await refresh();
    } catch (e) {
      toast({ title: "Not done", description: e instanceof Error ? e.message : "request failed", variant: "destructive" });
    } finally { setBusy(false); }
  };

  const rt = useClientTable<ReportRow>(reportRows, {
    rowKey: (r) => String(r.id),
    searchText: (r) => `${r.reporter_name ?? ""} ${r.reported_name ?? ""} ${REASON_TEXT[r.reason]} ${r.note ?? ""}`,
    sorts: {
      reason: (a, b) => cmpText(a.reason, b.reason), reporter: (a, b) => cmpText(a.reporter_name, b.reporter_name), reported: (a, b) => cmpText(a.reported_name, b.reported_name),
      count: (a, b) => cmpNum(a.reports_30d, b.reports_30d), date: (a, b) => cmpDate(a.created_at, b.created_at),
    },
    defaultSort: { key: "date", dir: "desc" },
  });
  const wt = useClientTable<WatchRow>(watchRows, {
    rowKey: (w) => w.user_id,
    searchText: (w) => `${w.full_name ?? ""} ${w.username ?? ""}`,
    sorts: {
      member: (a, b) => cmpText(a.full_name, b.full_name), reports: (a, b) => cmpNum(a.reports_30d, b.reports_30d), open: (a, b) => cmpNum(a.open_reports, b.open_reports),
      reporters: (a, b) => cmpNum(a.reporters, b.reporters), last: (a, b) => cmpDate(a.last_report_at, b.last_report_at),
    },
    defaultSort: { key: "reports", dir: "desc" },
  });

  const reportColumns = useMemo<DTColumn<ReportRow>[]>(() => [
    { key: "reason", header: "Reason", sortKey: "reason", cell: (r) => <Badge variant={r.reason === "threat" || r.reason === "nudity" ? "destructive" : "secondary"}>{REASON_TEXT[r.reason]}</Badge> },
    { key: "reported", header: "Reported", sortKey: "reported", cell: (r) => <span className="inline-flex items-center gap-1 font-medium">{who(r.reported_name, r.reported_id)}{r.reported_id && <AutoBadge userId={r.reported_id} only="verified" />}</span> },
    { key: "reporter", header: "Reported by", sortKey: "reporter", cell: (r) => <span className="inline-flex items-center gap-1 text-sm">{who(r.reporter_name, r.reporter_id)}<AutoBadge userId={r.reporter_id} only="verified" /></span> },
    { key: "count", header: "Reports (30 d)", sortKey: "count", cell: (r) => (r.reports_30d > 1 ? <Badge variant="outline">{r.reports_30d}</Badge> : <span className="text-muted-foreground">{r.reports_30d}</span>) },
    { key: "date", header: "When", sortKey: "date", className: "whitespace-nowrap", cell: (r) => <span className="text-sm text-muted-foreground">{when(r.created_at)}</span> },
    { key: "act", header: "", className: "w-32 text-right", cell: (r) => (r.status === "open"
      ? <Button size="sm" variant="outline" disabled={busy} onClick={(e) => { e.stopPropagation(); void closeMany([r.id]); }}><CheckCircle2 className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Mark done</Button>
      : <span className="text-xs text-muted-foreground">Closed {when(r.handled_at)}</span>) },
    // eslint-disable-next-line react-hooks/exhaustive-deps -- closeMany only reads state through setters
  ], [busy]);

  const watchColumns = useMemo<DTColumn<WatchRow>[]>(() => [
    { key: "member", header: "Member", sortKey: "member", cell: (w) => (
      <div className="flex items-center gap-3">
        <MemberAvatar m={{ avatar_url: w.avatar_url, full_name: w.full_name, email: null }} size={32} />
        <div className="min-w-0"><p className="flex items-center gap-1 font-medium"><span className="truncate">{w.full_name || (w.username ? `@${w.username}` : w.user_id.slice(0, 8))}</span><AutoBadge userId={w.user_id} only="verified" /></p>{w.username && <p className="truncate text-xs text-muted-foreground">@{w.username}</p>}</div>
      </div>) },
    { key: "reports", header: "Reports (30 d)", sortKey: "reports", cell: (w) => <Badge variant={w.open_reports > 0 ? "destructive" : "outline"}>{w.reports_30d}</Badge> },
    { key: "open", header: "Open now", sortKey: "open", cell: (w) => <span className={w.open_reports > 0 ? "font-medium" : "text-muted-foreground"}>{w.open_reports}</span> },
    { key: "reporters", header: "From members", sortKey: "reporters", cell: (w) => <span className="text-sm">{w.reporters}</span> },
    { key: "last", header: "Last report", sortKey: "last", className: "whitespace-nowrap", cell: (w) => <span className="text-sm text-muted-foreground">{when(w.last_report_at)}</span> },
    { key: "state", header: "Status", cell: (w) => (w.paused ? <Badge variant="destructive">Paused</Badge> : <span className="text-sm text-muted-foreground">Active</span>) },
  ], []);

  const exportReports = () => downloadCsv(`message-reports-${tab}.csv`, ["Reason", "Reported", "Reported by", "Reports 30 d", "When", "Note", "Status"],
    rt.filtered.map((r) => [REASON_TEXT[r.reason], who(r.reported_name, r.reported_id), who(r.reporter_name, r.reporter_id), r.reports_30d, r.created_at, r.note, r.status]));
  const exportWatch = () => downloadCsv("message-watch-list.csv", ["Member", "Username", "Reports 30 d", "Open", "From members", "Last report", "Paused"],
    wt.filtered.map((w) => [w.full_name, w.username, w.reports_30d, w.open_reports, w.reporters, w.last_report_at, w.paused]));

  const tabs = [
    { key: "open", label: "Open reports", count: open.data?.length ?? null, warn: true },
    { key: "done", label: "Done", count: done.data?.length ?? null },
    { key: "watch", label: "Watch list", count: watch.data?.length ?? null },
  ];
  const onTab = (k: string) => { setTab(k as Tab); rt.setSelected(new Set()); rt.setPage(0); wt.setPage(0); };
  const note = "Reports are the only queue: nothing else waits for you. The watch list shows the members reported most in the last 30 days.";

  return (
    <div className="space-y-3" data-testid="messages-reports">
      <p className="text-xs text-muted-foreground">{note}</p>
      {tab !== "watch" ? (
        <AdminDataTable<ReportRow>
          testId="messages-reports-table"
          rows={rt.view}
          rowKey={(r) => String(r.id)}
          columns={reportColumns}
          tabs={tabs}
          tab={tab}
          onTab={onTab}
          search={rt.search}
          onSearch={rt.setSearch}
          searchPlaceholder="Search names, reason or note"
          toolbar={<Button variant="outline" size="sm" className="h-9" onClick={exportReports} disabled={rt.total === 0}><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export</Button>}
          sort={rt.sort}
          onSort={rt.onSort}
          selected={tab === "open" ? rt.selected : undefined}
          onSelectedChange={tab === "open" ? rt.setSelected : undefined}
          bulkBar={() => (
            <Button size="sm" disabled={busy} onClick={() => void closeMany(rt.pickedRows.map((r) => r.id)).then(() => rt.setSelected(new Set()))}>
              <CheckCircle2 className="mr-1 h-4 w-4" aria-hidden="true" />Mark done
            </Button>
          )}
          page={rt.page}
          pageSize={rt.pageSize}
          total={rt.total}
          onPage={rt.setPage}
          onPageSize={rt.setPageSize}
          loading={tab === "done" ? done.isLoading : open.isLoading}
          error={(tab === "done" ? done.error : open.error) ? "Could not read the reports." : null}
          emptyText={rt.search ? `No report matches “${rt.search}”.` : tab === "open" ? "No open reports." : "Nothing closed yet."}
          onRowClick={setPicked}
          phoneCard={(r) => (
            <div className="space-y-1">
              <div className="flex items-center gap-2"><Badge variant={r.reason === "threat" || r.reason === "nudity" ? "destructive" : "secondary"}>{REASON_TEXT[r.reason]}</Badge><span className="text-xs text-muted-foreground">{when(r.created_at)}</span></div>
              <p className="text-sm"><MemberName userId={r.reporter_id}><b>{who(r.reporter_name, r.reporter_id)}</b></MemberName> reported <MemberName userId={r.reported_id}><b>{who(r.reported_name, r.reported_id)}</b></MemberName></p>
              {r.note && <p className="text-xs text-muted-foreground">“{r.note}”</p>}
            </div>
          )}
        />
      ) : (
        <AdminDataTable<WatchRow>
          testId="messages-watch-table"
          rows={wt.view}
          rowKey={(w) => w.user_id}
          columns={watchColumns}
          tabs={tabs}
          tab={tab}
          onTab={onTab}
          search={wt.search}
          onSearch={wt.setSearch}
          searchPlaceholder="Search member"
          toolbar={<Button variant="outline" size="sm" className="h-9" onClick={exportWatch} disabled={wt.total === 0}><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export</Button>}
          sort={wt.sort}
          onSort={wt.onSort}
          page={wt.page}
          pageSize={wt.pageSize}
          total={wt.total}
          onPage={wt.setPage}
          onPageSize={wt.setPageSize}
          loading={watch.isLoading}
          error={watch.error ? "Could not read the watch list." : null}
          emptyText={wt.search ? `No one matches “${wt.search}”.` : "No one has been reported."}
          phoneCard={(w) => (
            <div className="flex items-center gap-2">
              <div className="min-w-0 flex-1"><p className="truncate font-medium">{w.full_name || (w.username ? `@${w.username}` : w.user_id.slice(0, 8))}</p><p className="text-xs text-muted-foreground">from {w.reporters} member{w.reporters === 1 ? "" : "s"} · last {when(w.last_report_at)}</p></div>
              <Badge variant={w.open_reports > 0 ? "destructive" : "outline"}>{w.reports_30d}</Badge>
              {w.paused && <Badge variant="destructive">Paused</Badge>}
            </div>
          )}
        />
      )}

      <AdminSidePanel
        wide open={!!picked} onClose={() => setPicked(null)} testId="report-side-panel"
        title={picked ? <>{REASON_TEXT[picked.reason]} · <MemberName userId={picked.reported_id} name={who(picked.reported_name, picked.reported_id)} /></> : ""}
        subtitle={picked ? `Reported by ${who(picked.reporter_name, picked.reporter_id)} · ${when(picked.created_at)}` : undefined}
        footer={picked && picked.status === "open" && (
          <Button disabled={busy} onClick={() => void closeMany([picked.id]).then(() => setPicked(null))}><CheckCircle2 className="mr-1 h-4 w-4" aria-hidden="true" />Mark done</Button>
        )}
      >
        {picked && (
          <>
            <div className="grid grid-cols-2 gap-4">
              <PanelField label="Reason">{REASON_TEXT[picked.reason]}</PanelField>
              <PanelField label="Reports in 30 days">{picked.reports_30d}</PanelField>
            </div>
            {picked.note && <PanelField label="What they wrote">“{picked.note}”</PanelField>}
            {picked.status === "done" && <PanelField label="Closed">{when(picked.handled_at)}</PanelField>}
            <div className="flex justify-end"><ExportChatButton userId={picked.reporter_id} conversationId={picked.conversation_id} /></div>
            <PanelField label="The chat, as the reporter sees it (read only)">
              <ViewAsProvider value={{ userId: picked.reporter_id, name: who(picked.reporter_name, picked.reporter_id) }}>
                <div className="mt-1.5 h-[min(60vh,520px)] overflow-hidden rounded-2xl border border-border bg-background">
                  <ChatPane key={picked.conversation_id} conversationId={picked.conversation_id} userId={null} onBack={() => setPicked(null)} />
                </div>
              </ViewAsProvider>
            </PanelField>
          </>
        )}
      </AdminSidePanel>
    </div>
  );
}

/**
 * M10 · Admin → Messages → "Reports": what members reported (the only queue there is —
 * there is no approval of ordinary messages) and the watch list (members reported most
 * in the last 30 days). No reason box: closing a report is one click.
 */
import { useState } from "react";
import { CheckCircle2, Loader2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { toast } from "@/hooks/core/use-toast";
import {
  adminMessageCall, useMessageReports, useMessageWatchlist, useRefreshAdminMessages, type ReportReasonKey,
} from "@/hooks/admin/useAdminMessages";

export const REASON_TEXT: Record<ReportReasonKey, string> = {
  spam: "Spam", abuse: "Abuse", threat: "Threats", nudity: "Nudity", other: "Other",
};
const when = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};

export default function ReportsPanel() {
  const [status, setStatus] = useState<"open" | "done">("open");
  const reports = useMessageReports(status);
  const watch = useMessageWatchlist();
  const refresh = useRefreshAdminMessages();
  const [busy, setBusy] = useState<number | null>(null);

  const close = async (id: number) => {
    setBusy(id);
    try {
      await adminMessageCall("admin_message_report_done", { _id: id, _note: null });
      await refresh();
    } catch (e) {
      toast({ title: "Not done", description: e instanceof Error ? e.message : "request failed", variant: "destructive" });
    } finally { setBusy(null); }
  };

  const rows = reports.data ?? [];
  return (
    <div className="space-y-6" data-testid="messages-reports">
      <section aria-label="Reports" className="space-y-2">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="text-sm font-semibold">Reports from members</h3>
          <div className="flex gap-1" role="group" aria-label="Filter reports">
            <Button size="sm" variant={status === "open" ? "default" : "outline"} onClick={() => setStatus("open")}>Open</Button>
            <Button size="sm" variant={status === "done" ? "default" : "outline"} onClick={() => setStatus("done")}>Done</Button>
          </div>
        </div>
        {reports.isLoading && <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" aria-label="Loading" />}
        {reports.error && <p className="text-sm text-destructive">Could not read the reports.</p>}
        {reports.data && rows.length === 0 && <p className="rounded-lg border border-dashed border-border p-4 text-center text-sm text-muted-foreground">{status === "open" ? "No open reports." : "Nothing closed yet."}</p>}
        {rows.length > 0 && (
          <ul className="divide-y divide-border rounded-lg border border-border">
            {rows.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center gap-2 p-2 text-sm" data-testid="messages-report-row">
                <Badge variant={r.reason === "threat" || r.reason === "nudity" ? "destructive" : "secondary"}>{REASON_TEXT[r.reason]}</Badge>
                <span><b>{r.reporter_name || r.reporter_id.slice(0, 8)}</b> reported <b>{r.reported_name || (r.reported_id ? r.reported_id.slice(0, 8) : "a group chat")}</b></span>
                {r.reports_30d > 1 && <Badge variant="outline">{r.reports_30d} reports in 30 days</Badge>}
                <span className="text-xs text-muted-foreground">{when(r.created_at)}</span>
                {r.note && <span className="w-full text-xs text-muted-foreground">“{r.note}”</span>}
                {r.status === "open" && (
                  <Button size="sm" variant="outline" className="ml-auto" disabled={busy === r.id} onClick={() => void close(r.id)}>
                    <CheckCircle2 className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Mark done
                  </Button>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-label="Watch list" className="space-y-2" data-testid="messages-watch">
        <h3 className="text-sm font-semibold">Watch list <span className="font-normal text-muted-foreground">· most reported, last 30 days</span></h3>
        {watch.data && watch.data.length === 0 && <p className="text-sm text-muted-foreground">No one has been reported.</p>}
        {watch.data && watch.data.length > 0 && (
          <ul className="divide-y divide-border rounded-lg border border-border">
            {watch.data.map((w) => (
              <li key={w.user_id} className="flex flex-wrap items-center gap-2 p-2 text-sm" data-testid="messages-watch-row">
                <span className="font-medium">{w.full_name || (w.username ? `@${w.username}` : w.user_id.slice(0, 8))}</span>
                <Badge variant={w.open_reports > 0 ? "destructive" : "outline"}>{w.reports_30d} report{w.reports_30d === 1 ? "" : "s"}</Badge>
                <span className="text-xs text-muted-foreground">from {w.reporters} member{w.reporters === 1 ? "" : "s"} · last {when(w.last_report_at)}</span>
                {w.paused && <Badge variant="destructive">Paused</Badge>}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

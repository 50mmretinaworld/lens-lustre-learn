/**
 * J5a · ADMIN → Overview → Job Engine. Routed at /admin/jobs (via AdminPanel).
 * READ ONLY: what the job engine ran, what failed, what is waiting.
 * Data: useAdminJobs (admin-only rpcs, 20261118_0900). No payload is ever shown.
 */
import { useState } from "react";
import { Loader2, AlertTriangle, CheckCircle2, XCircle, Clock, PlayCircle, RefreshCw } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  useAdminJobsOverview, useAdminJobsList, jobKindLabel,
  type JobKindRow, type JobStatus,
} from "@/hooks/admin/useAdminJobs";

const SWITCH_LABEL: Record<string, string> = {
  job_engine: "Job engine",
  job_engine_push: "Push notifications",
  job_engine_cron_http: "Timer tasks",
};

const STATUS_LABEL: Record<JobStatus, string> = {
  queued: "Waiting", running: "Running", done: "Done", failed: "Failed", cancelled: "Cancelled",
};

export const fmtWhen = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};

export const fmtSeconds = (s: number | null) => {
  if (s === null) return "—";
  if (s < 90) return `${Math.round(s)} s`;
  if (s < 5400) return `${Math.round(s / 60)} min`;
  return `${Math.round(s / 3600)} h`;
};

function StatusBadge({ status }: { status: JobStatus }) {
  const variant = status === "failed" ? "destructive" : status === "done" ? "secondary" : "outline";
  return <Badge variant={variant}>{STATUS_LABEL[status]}</Badge>;
}

function KindCard({ k, selected, onSelect }: { k: JobKindRow; selected: boolean; onSelect: () => void }) {
  const bad = k.failed_24h > 0;
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      data-testid="job-kind-card"
      className={`w-full rounded-lg border p-3 text-left transition-colors ${selected ? "border-primary bg-primary/5" : "border-border hover:bg-muted/40"}`}
    >
      <div className="flex items-center justify-between gap-2">
        <span className="font-medium">{jobKindLabel(k.kind)}</span>
        {!k.enabled ? <Badge variant="outline">Off</Badge>
          : bad ? <Badge variant="destructive">{k.failed_24h} failed</Badge>
          : <Badge variant="secondary">OK</Badge>}
      </div>
      <div className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-xs text-muted-foreground sm:grid-cols-4">
        <span className="flex items-center gap-1"><CheckCircle2 className="h-3.5 w-3.5" aria-hidden="true" />Done 24 h: <b className="text-foreground">{k.done_24h}</b></span>
        <span className="flex items-center gap-1"><XCircle className="h-3.5 w-3.5" aria-hidden="true" />Failed 24 h: <b className={bad ? "text-destructive" : "text-foreground"}>{k.failed_24h}</b></span>
        <span className="flex items-center gap-1"><PlayCircle className="h-3.5 w-3.5" aria-hidden="true" />Running: <b className="text-foreground">{k.running}</b> / {k.max_running}</span>
        <span className="flex items-center gap-1"><Clock className="h-3.5 w-3.5" aria-hidden="true" />Waiting: <b className="text-foreground">{k.queued}</b></span>
      </div>
      <div className="mt-1 text-xs text-muted-foreground">
        Average time: {fmtSeconds(k.avg_seconds_24h)} · Last done: {fmtWhen(k.last_done_at)} · Tries: {k.max_attempts}
      </div>
      {k.last_error && (
        <div className="mt-1 truncate text-xs text-destructive" title={k.last_error}>
          Last error ({fmtWhen(k.last_failed_at)}): {k.last_error}
        </div>
      )}
    </button>
  );
}

const FILTERS: { key: JobStatus | null; label: string }[] = [
  { key: null, label: "All" }, { key: "failed", label: "Failed" }, { key: "queued", label: "Waiting" },
  { key: "running", label: "Running" }, { key: "done", label: "Done" },
];

const AdminJobs = () => {
  const overview = useAdminJobsOverview();
  const [status, setStatus] = useState<JobStatus | null>(null);
  const [kind, setKind] = useState<string | null>(null);
  const list = useAdminJobsList(status, kind);
  const ov = overview.data;

  return (
    <div className="space-y-6 px-4 py-4 sm:px-0" data-testid="admin-jobs">
      <header className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-lg font-semibold" style={{ fontFamily: "var(--font-heading)" }}>Job Engine</h2>
          <p className="mt-1 text-[11px] text-muted-foreground">
            Background work the site runs: what ran, what failed, what is waiting. Read only. Checked {fmtWhen(ov?.checked_at ?? null)}.
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={() => { void overview.refetch(); void list.refetch(); }}>
          <RefreshCw className="mr-1 h-4 w-4" aria-hidden="true" />Refresh
        </Button>
      </header>

      {overview.isLoading && <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin text-muted-foreground" aria-label="Loading" /></div>}
      {overview.error && <p className="rounded-lg border border-destructive p-3 text-sm text-destructive">Could not read the job engine: {(overview.error as Error).message}</p>}

      {ov && (
        <>
          <section aria-label="Switches" className="flex flex-wrap gap-2">
            {Object.keys(SWITCH_LABEL).map((key) => (
              <Badge key={key} variant={ov.switches[key] ? "secondary" : "outline"} data-testid="job-switch">
                {SWITCH_LABEL[key]}: {ov.switches[key] ? "On" : "Off"}
              </Badge>
            ))}
          </section>

          {ov.alarms.length > 0 && (
            <section aria-label="Open alarms" className="space-y-2 rounded-lg border border-destructive p-3" data-testid="job-alarms">
              {ov.alarms.map((a) => (
                <p key={a.alarm_key} className="flex items-start gap-2 text-sm text-destructive">
                  <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                  <span><b>{a.summary ?? a.alarm_key}</b> · since {fmtWhen(a.opened_at)}</span>
                </p>
              ))}
            </section>
          )}

          <section aria-label="Job kinds" className="grid gap-2 lg:grid-cols-2">
            {ov.kinds.map((k) => (
              <KindCard key={k.kind} k={k} selected={kind === k.kind} onSelect={() => setKind(kind === k.kind ? null : k.kind)} />
            ))}
          </section>
        </>
      )}

      <section aria-label="Recent jobs" className="space-y-2">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="text-sm font-semibold">Recent jobs{kind ? ` · ${jobKindLabel(kind)}` : ""}</h3>
          <div className="flex flex-wrap gap-1" role="group" aria-label="Filter by status">
            {FILTERS.map((f) => (
              <Button key={f.label} size="sm" variant={status === f.key ? "default" : "outline"} onClick={() => setStatus(f.key)}>
                {f.label}
              </Button>
            ))}
          </div>
        </div>
        {list.isLoading && <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" aria-label="Loading" />}
        {list.error && <p className="text-sm text-destructive">Could not read the job list.</p>}
        {list.data && list.data.length === 0 && <p className="text-sm text-muted-foreground">No jobs here.</p>}
        {list.data && list.data.length > 0 && (
          <ul className="divide-y divide-border rounded-lg border border-border" data-testid="job-list">
            {list.data.map((j) => (
              <li key={j.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 p-2 text-sm" data-testid="job-row">
                <StatusBadge status={j.status} />
                <span className="font-medium">{jobKindLabel(j.kind)}</span>
                <span className="text-xs text-muted-foreground">#{j.id} · try {j.attempts}/{j.max_attempts} · made {fmtWhen(j.created_at)}{j.finished_at ? ` · finished ${fmtWhen(j.finished_at)}` : ""}</span>
                {j.last_error && <span className="w-full truncate text-xs text-destructive" title={j.last_error}>{j.last_error}</span>}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
};

export default AdminJobs;

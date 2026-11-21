/**
 * M12 · the small pieces every Broadcast screen draws the same way: status chip, the double-tick (grey = delivered,
 * blue = read), a count card, time formatting.
 */
import { AlertCircle, CheckCheck, Clock, Loader2, PauseCircle, Send, XCircle, Ban, FileEdit, Undo2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import type { BcStatus } from "@/hooks/admin/useAdminBroadcasts";
import { audienceLabel } from "@/hooks/admin/usePushCentre";
import type { PushAudience } from "@/hooks/admin/usePushCentre";

export const fmtWhen = (iso: string | null | undefined) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};
export const pct = (n: number, of: number) => (of > 0 ? Math.round((n / of) * 100) : 0);
export const audienceText = (a: PushAudience) => audienceLabel(a);

const META: Record<BcStatus, { label: string; cls: string; icon: typeof Send }> = {
  draft: { label: "Draft", cls: "border-border bg-muted text-muted-foreground", icon: FileEdit },
  scheduled: { label: "Scheduled", cls: "border-sky-500/30 bg-sky-500/10 text-sky-700 dark:text-sky-300", icon: Clock },
  sending: { label: "Sending", cls: "border-primary/40 bg-primary/10 text-primary", icon: Loader2 },
  paused: { label: "Paused", cls: "border-amber-500/30 bg-amber-500/10 text-amber-700 dark:text-amber-300", icon: PauseCircle },
  done: { label: "Done", cls: "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300", icon: CheckCheck },
  cancelled: { label: "Cancelled", cls: "border-border bg-muted text-muted-foreground", icon: Ban },
  withdrawn: { label: "Withdrawn", cls: "border-destructive/40 bg-destructive/10 text-destructive", icon: Undo2 },
};

export function BcStatusChip({ status }: { status: BcStatus }) {
  const m = META[status];
  const Icon = m.icon;
  return (
    <span className={cn("inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium", m.cls)} data-testid={`bc-status-${status}`}>
      <Icon className={cn("h-3 w-3", status === "sending" && "animate-spin")} aria-hidden="true" />{m.label}
    </span>
  );
}
export const STATUS_LABEL = (s: BcStatus) => META[s].label;

/** The tick the member's own screen uses: one grey = sent, two grey = delivered, two blue = read. */
export function Ticks({ state }: { state: "delivered" | "read" | "failed" | "waiting" | "withdrawn" }) {
  if (state === "failed") return <XCircle className="h-4 w-4 text-destructive" aria-label="Failed" />;
  if (state === "waiting") return <Clock className="h-4 w-4 text-muted-foreground" aria-label="Waiting" />;
  if (state === "withdrawn") return <Undo2 className="h-4 w-4 text-muted-foreground" aria-label="Withdrawn" />;
  return <CheckCheck className={cn("h-4 w-4", state === "read" ? "text-sky-500" : "text-muted-foreground")} aria-label={state === "read" ? "Read" : "Delivered"} />;
}

export function CountCard({ label, value, sub, tone, testId }: { label: string; value: number; sub?: string; tone?: "good" | "bad" | "blue"; testId?: string }) {
  return (
    <div className="rounded-xl border border-border bg-card p-3" data-testid={testId}>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={cn("mt-0.5 text-2xl font-semibold tabular-nums", tone === "bad" && value > 0 && "text-destructive", tone === "blue" && "text-sky-500")}>{value.toLocaleString()}</p>
      {sub && <p className="text-[11px] text-muted-foreground">{sub}</p>}
    </div>
  );
}

export function EngineWarning({ on }: { on: boolean }) {
  if (on) return null;
  return (
    <p role="alert" className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-800 dark:text-amber-200">
      <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
      <span>The job engine is switched off, so batches will wait and nothing is delivered until it is turned on (Admin → Job Engine).</span>
    </p>
  );
}

export function BatchChip({ status }: { status: string }) {
  const variant = status === "failed" ? "destructive" : status === "done" ? "secondary" : "outline";
  return <Badge variant={variant} className="capitalize">{status}</Badge>;
}

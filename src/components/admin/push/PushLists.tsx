/**
 * PUSH CENTRE (PN3) — History (every send with its real outcome), Scheduled
 * (cancel until it goes), Drafts and Templates.
 */
import { Fragment, useState } from "react";
import { ChevronDown, Copy, Loader2, Pencil, Trash2, XCircle } from "lucide-react";
import { toast } from "@/hooks/core/use-toast";
import { cn } from "@/lib/utils";
import { useIsMobile } from "@/hooks/core/use-mobile";
import OptimizedImage from "@/components/OptimizedImage";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { useMemberLabels } from "@/components/admin/users/memberUi";
import {
  audienceLabel, broadcastToDraft, usePushBroadcasts, usePushWrites,
  type PushBroadcast, type PushDraft, type PushView,
} from "@/hooks/admin/usePushCentre";
import { PushStatusChip, fmtWhen } from "./pushUi";

const pct = (n: number, of: number | null) => (of && of > 0 ? `${Math.round((n / of) * 100)}%` : "—");

/** FCM reason words → what an admin can act on. */
const REASON: Record<string, string> = {
  UNREGISTERED: "app removed from the phone",
  NOT_FOUND: "app removed from the phone",
  SENDER_ID_MISMATCH: "an old app copy",
  INVALID_ARGUMENT: "the phone refused the message",
  QUOTA_EXCEEDED: "Google's limit — try later",
  UNAVAILABLE: "Google was busy",
  INTERNAL: "Google error",
  NETWORK: "network error",
  NOT_CONFIGURED: "not sent — push is not set up on this site",
  GOOGLE_SIGN_IN: "not sent — Google refused our sign-in",
  DATABASE: "not sent — the list of phones could not be read",
  SEND_STOPPED: "not sent — the send stopped part-way",
};
function reasonText(code: string): string {
  const word = code.split(" ").pop() ?? code;
  return REASON[word] ?? word.toLowerCase().replace(/_/g, " ");
}

function Thumb({ b }: { b: PushBroadcast }) {
  const src = b.image_url || b.images[0];
  return src
    ? <OptimizedImage src={src} alt="" className="h-9 w-9 shrink-0 rounded object-cover" />
    : <div className="h-9 w-9 shrink-0 rounded bg-muted" />;
}

function useLabelFor() {
  const labels = useMemberLabels();
  return (kind: "role" | "badge", key: string) => (kind === "role" ? labels.role(key).label : labels.badge(key).label);
}

function Outcome({ b }: { b: PushBroadcast }) {
  const reasons = Object.entries(b.fail_reasons);
  return (
    <div className="grid gap-3 rounded-lg bg-muted/40 p-3 text-xs sm:grid-cols-2" data-testid="push-history-detail">
      <div className="space-y-1">
        <p className="font-semibold">{b.title}</p>
        {b.body && <p className="whitespace-pre-line text-muted-foreground">{b.body}</p>}
        <p className="text-[11px] text-muted-foreground">
          {b.link ? <>Opens <span className="font-mono">{b.link}</span></> : "Opens the app"}
          {b.countdown_until && <> · countdown to {fmtWhen(b.countdown_until)}</>}
          {b.actions.length > 0 && <> · buttons: {b.actions.map((a) => a.label).join(", ")}</>}
        </p>
      </div>
      <div className="space-y-1 text-[11px]">
        <p>Audience: <strong>{b.audience_members ?? "—"}</strong> members · with a phone <strong>{b.reached_members ?? "—"}</strong> · phones <strong>{b.devices ?? "—"}</strong></p>
        <p>Delivered <strong>{b.delivered}</strong> · failed <strong>{b.failed}</strong> · removed <strong>{b.removed}</strong> · opened <strong>{b.opened}</strong></p>
        {reasons.length > 0 && (
          <div className="flex flex-wrap gap-1 pt-1">
            {reasons.map(([code, n]) => (
              <span key={code} className="rounded-full border border-destructive/30 bg-destructive/5 px-2 py-0.5 text-[10px] text-destructive">
                {n} × {reasonText(code)}
              </span>
            ))}
          </div>
        )}
        {b.stuck && <p className="text-destructive">The send stopped part-way and did not finish. The numbers above are what was recorded.</p>}
      </div>
    </div>
  );
}

function History({ onCopy }: { onCopy: (d: PushDraft) => void }) {
  const [page, setPage] = useState(0);
  const { data, isLoading } = usePushBroadcasts("history", page);
  const [open, setOpen] = useState<number | null>(null);
  const isMobile = useIsMobile();
  const labelFor = useLabelFor();
  const items = data?.items ?? [];
  if (isLoading) return <p className="py-10 text-center text-xs text-muted-foreground"><Loader2 className="mr-2 inline h-4 w-4 animate-spin" />Loading…</p>;
  if (!items.length) return <p className="py-10 text-center text-xs text-muted-foreground">Nothing sent from this page yet. Every send will be listed here with what happened.</p>;

  const copy = (b: PushBroadcast) => { onCopy(broadcastToDraft(b, true)); toast({ title: "Copied into a new message" }); };

  return (
    <div className="space-y-3">
      {isMobile ? (
        <ul className="space-y-2">
          {items.map((b) => (
            <li key={b.id} className="rounded-xl border border-border p-3" data-testid="push-history-row">
              <button type="button" className="flex w-full items-start gap-2.5 text-left" onClick={() => setOpen(open === b.id ? null : b.id)}>
                <Thumb b={b} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-xs font-semibold">{b.title}</span>
                  <span className="block text-[10px] text-muted-foreground">{fmtWhen(b.started_at ?? b.updated_at)} · {audienceLabel(b.audience, labelFor)}</span>
                  <span className="mt-1 block text-[11px]">Delivered <strong>{b.delivered}</strong>/{b.devices ?? 0} · opened <strong>{b.opened}</strong> ({pct(b.opened, b.delivered)})</span>
                </span>
                <PushStatusChip status={b.status} stuck={b.stuck} />
              </button>
              {open === b.id && <div className="mt-2 space-y-2"><Outcome b={b} /><Button size="sm" variant="outline" className="h-8 text-[11px]" onClick={() => copy(b)}><Copy className="mr-1.5 h-3.5 w-3.5" />Send again</Button></div>}
            </li>
          ))}
        </ul>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-[130px]">Sent</TableHead>
              <TableHead>Message</TableHead>
              <TableHead>To</TableHead>
              <TableHead className="text-right">Phones</TableHead>
              <TableHead className="text-right">Delivered</TableHead>
              <TableHead className="text-right">Opened</TableHead>
              <TableHead className="text-right">Failed</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="w-8" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {items.map((b) => (
              <Fragment key={b.id}>
                <TableRow className="cursor-pointer" onClick={() => setOpen(open === b.id ? null : b.id)} data-testid="push-history-row">
                  <TableCell className="text-[11px] text-muted-foreground">{fmtWhen(b.started_at ?? b.updated_at)}<span className="block text-[10px]">{b.sent_by_name ?? ""}</span></TableCell>
                  <TableCell><div className="flex items-center gap-2.5"><Thumb b={b} /><span className="min-w-0"><span className="block max-w-[280px] truncate text-xs font-semibold">{b.title}</span><span className="block max-w-[280px] truncate text-[11px] text-muted-foreground">{b.body}</span></span></div></TableCell>
                  <TableCell className="text-[11px]">{audienceLabel(b.audience, labelFor)}</TableCell>
                  <TableCell className="text-right font-mono text-xs">{b.devices ?? "—"}</TableCell>
                  <TableCell className="text-right font-mono text-xs">{b.delivered}<span className="block text-[10px] text-muted-foreground">{pct(b.delivered, b.devices)}</span></TableCell>
                  <TableCell className="text-right font-mono text-xs">{b.opened}<span className="block text-[10px] text-muted-foreground">{pct(b.opened, b.delivered)}</span></TableCell>
                  <TableCell className={cn("text-right font-mono text-xs", b.failed > 0 && "text-destructive")}>{b.failed}{b.removed > 0 && <span className="block text-[10px] text-muted-foreground">{b.removed} removed</span>}</TableCell>
                  <TableCell><PushStatusChip status={b.status} stuck={b.stuck} /></TableCell>
                  <TableCell><ChevronDown className={cn("h-4 w-4 text-muted-foreground transition-transform", open === b.id && "rotate-180")} /></TableCell>
                </TableRow>
                {open === b.id && (
                  <TableRow className="hover:bg-transparent">
                    <TableCell colSpan={9} className="pb-4">
                      <Outcome b={b} />
                      <Button size="sm" variant="outline" className="mt-2 h-8 text-[11px]" onClick={() => copy(b)}><Copy className="mr-1.5 h-3.5 w-3.5" />Send again</Button>
                    </TableCell>
                  </TableRow>
                )}
              </Fragment>
            ))}
          </TableBody>
        </Table>
      )}
      {(data?.total ?? 0) > 25 && (
        <div className="flex items-center justify-end gap-2 text-[11px]">
          <Button size="sm" variant="outline" className="h-8" disabled={page === 0} onClick={() => setPage(page - 1)}>Newer</Button>
          <span>{page * 25 + 1}–{Math.min((page + 1) * 25, data?.total ?? 0)} of {data?.total}</span>
          <Button size="sm" variant="outline" className="h-8" disabled={(page + 1) * 25 >= (data?.total ?? 0)} onClick={() => setPage(page + 1)}>Older</Button>
        </div>
      )}
    </div>
  );
}

function SimpleList({ view, onEdit }: { view: Exclude<PushView, "history">; onEdit: (d: PushDraft) => void }) {
  const { data, isLoading } = usePushBroadcasts(view);
  const writes = usePushWrites();
  const labelFor = useLabelFor();
  const [busy, setBusy] = useState<number | null>(null);
  const items = data?.items ?? [];
  const empty = {
    scheduled: "Nothing is scheduled. Pick “Schedule” when you write a message.",
    drafts: "No drafts. “Save draft” keeps a message here to finish later.",
    templates: "No templates. “Save as template” keeps a message you send often.",
  }[view];
  if (isLoading) return <p className="py-10 text-center text-xs text-muted-foreground"><Loader2 className="mr-2 inline h-4 w-4 animate-spin" />Loading…</p>;
  if (!items.length) return <p className="py-10 text-center text-xs text-muted-foreground">{empty}</p>;

  const act = async (b: PushBroadcast, what: "cancel" | "delete") => {
    setBusy(b.id);
    const err = what === "cancel" ? await writes.cancel(b.id) : await writes.remove(b.id);
    setBusy(null);
    toast(err ? { title: "Not done", description: err, variant: "destructive" } : { title: what === "cancel" ? "Cancelled — it will not be sent" : "Deleted" });
  };

  return (
    <ul className="divide-y divide-border rounded-xl border border-border" data-testid={`push-${view}-list`}>
      {items.map((b) => (
        <li key={b.id} className="flex flex-wrap items-center gap-3 p-3">
          <Thumb b={b} />
          <div className="min-w-0 flex-1">
            <p className="truncate text-xs font-semibold">{view === "templates" && b.name ? `${b.name} — ` : ""}{b.title}</p>
            <p className="truncate text-[11px] text-muted-foreground">
              {view === "scheduled" ? <>Goes {fmtWhen(b.scheduled_at)} · </> : <>Edited {fmtWhen(b.updated_at)} · </>}
              {audienceLabel(b.audience, labelFor)}
              {b.countdown_until && <> · countdown</>}
            </p>
          </div>
          {view === "scheduled" ? (
            <Button size="sm" variant="outline" className="h-8 text-[11px]" disabled={busy === b.id} onClick={() => act(b, "cancel")}>
              <XCircle className="mr-1.5 h-3.5 w-3.5" />Cancel
            </Button>
          ) : (
            <>
              <Button size="sm" variant="outline" className="h-8 text-[11px]" onClick={() => onEdit(broadcastToDraft(b, view === "templates"))}>
                {view === "templates" ? <><Copy className="mr-1.5 h-3.5 w-3.5" />Use</> : <><Pencil className="mr-1.5 h-3.5 w-3.5" />Edit</>}
              </Button>
              <Button size="sm" variant="ghost" className="h-8 px-2 text-muted-foreground hover:text-destructive" aria-label="Delete"
                disabled={busy === b.id} onClick={() => act(b, "delete")}><Trash2 className="h-3.5 w-3.5" /></Button>
            </>
          )}
        </li>
      ))}
    </ul>
  );
}

export function PushList({ view, onEdit }: { view: PushView; onEdit: (d: PushDraft) => void }) {
  return view === "history" ? <History onCopy={onEdit} /> : <SimpleList view={view} onEdit={onEdit} />;
}

/**
 * A4 · ADMIN → Users & Community → Account Review. Routed at
 * /admin/account_reviews (via AdminPanel).
 *
 * Owner decisions (2026-11-15):
 *   - Under review = the member can only look; they see ONLY "Your account is
 *     under review" + support@50mmretina.com (AccountStateBanner).
 *   - A member's own delete = a request: an admin approves (full wipe) or holds
 *     (unlimited); untouched for 180 days it is auto-approved by the job engine.
 *   - Admin delete = instant full wipe, no copy kept; the log row
 *     (who / when / reason) stays 1 year.
 *
 * Every action needs a reason. The database checks admin and the reason itself
 * (see useAccountReviews); this page only collects them.
 */
import { useState } from "react";
import { Loader2, History, ShieldAlert, UserCheck, Trash2, PauseCircle, CheckCircle2 } from "lucide-react";
import ProfileTypeaheadPicker from "@/components/admin/ProfileTypeaheadPicker";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Textarea } from "@/components/ui/textarea";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { toast } from "@/hooks/core/use-toast";
import {
  useAccountReviews, useAccountStateHistory, useAccountAction,
  type AccountAction, type AccountReviewRow,
} from "@/hooks/admin/useAccountReviews";

type Pending = { kind: AccountAction["kind"]; userId: string; name: string };

const fmt = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : "—");
const STATE_LABEL: Record<string, string> = {
  active: "Active",
  under_review: "Under review",
  deletion_requested: "Asked to be deleted",
};

export const ACTION_TEXT: Record<AccountAction["kind"], { title: string; button: string; body: (name: string) => string }> = {
  under_review: {
    title: "Put under review",
    button: "Put under review",
    body: (n) => `${n} will only be able to look. They see "Your account is under review" and the support e-mail.`,
  },
  active: {
    title: "Make active again",
    button: "Make active",
    body: (n) => `${n} can use the site normally again. Any deletion request is cleared.`,
  },
  approve: {
    title: "Approve deletion",
    button: "Delete now",
    body: (n) => `${n} asked to be deleted. Approving wipes the account now. This cannot be undone.`,
  },
  hold: {
    title: "Hold deletion",
    button: "Hold",
    body: (n) => `The deletion request of ${n} is held with no end date. The account stays under review.`,
  },
  delete: {
    title: "Delete member",
    button: "Delete now",
    body: (n) => `${n} and everything they posted is wiped now. No copy is kept. This cannot be undone.`,
  },
};

function HistoryList({ userId }: { userId: string }) {
  const { data, isLoading, error } = useAccountStateHistory(userId);
  if (isLoading) return <Loader2 className="h-4 w-4 animate-spin" aria-label="Loading" />;
  if (error) return <p className="text-xs text-muted-foreground">History not available.</p>;
  if (!data?.length) return <p className="text-xs text-muted-foreground">No history.</p>;
  return (
    <ol className="space-y-1 text-xs" data-testid="account-history">
      {data.map((h, i) => (
        <li key={`${h.created_at}-${i}`} className="flex flex-wrap gap-x-2">
          <span className="tabular-nums text-muted-foreground">{fmt(h.created_at)}</span>
          <span>{STATE_LABEL[h.from_state ?? "active"] ?? h.from_state} → {STATE_LABEL[h.to_state] ?? h.to_state}</span>
          <span className="text-muted-foreground">by {h.actor_name ?? "system"}</span>
          {h.reason && <span className="w-full pl-2 text-muted-foreground">“{h.reason}”</span>}
        </li>
      ))}
    </ol>
  );
}

function ReviewRow({ row, onAction }: { row: AccountReviewRow; onAction: (p: Pending) => void }) {
  const [showHistory, setShowHistory] = useState(false);
  const name = row.full_name ?? "Unnamed member";
  const asked = !!row.deletion_requested_at;
  return (
    <li className="space-y-2 rounded-lg border border-border p-3" data-testid="account-review-row">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-medium">{name}</span>
        <Badge variant={row.state === "deletion_requested" ? "destructive" : "secondary"}>{STATE_LABEL[row.state]}</Badge>
        {asked && row.state === "under_review" && <Badge variant="outline">Deletion held</Badge>}
      </div>
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-xs">
        <dt className="text-muted-foreground">Reason</dt><dd>{row.reason ?? "—"}</dd>
        <dt className="text-muted-foreground">Set</dt><dd>{fmt(row.set_at)} by {row.set_by_name ?? "system"}</dd>
        {asked && (<><dt className="text-muted-foreground">Asked to delete</dt><dd>{fmt(row.deletion_requested_at)}</dd></>)}
        {row.auto_approve_at && (<><dt className="text-muted-foreground">Auto-approve</dt><dd>{fmt(row.auto_approve_at)}</dd></>)}
      </dl>
      <div className="flex flex-wrap gap-2">
        {asked && (
          <>
            <Button size="sm" variant="destructive" onClick={() => onAction({ kind: "approve", userId: row.user_id, name })}>
              <CheckCircle2 className="mr-1 h-4 w-4" />Approve deletion
            </Button>
            {row.state === "deletion_requested" && (
              <Button size="sm" variant="outline" onClick={() => onAction({ kind: "hold", userId: row.user_id, name })}>
                <PauseCircle className="mr-1 h-4 w-4" />Hold
              </Button>
            )}
          </>
        )}
        <Button size="sm" variant="outline" onClick={() => onAction({ kind: "active", userId: row.user_id, name })}>
          <UserCheck className="mr-1 h-4 w-4" />Make active
        </Button>
        {!asked && (
          <Button size="sm" variant="outline" className="text-destructive" onClick={() => onAction({ kind: "delete", userId: row.user_id, name })}>
            <Trash2 className="mr-1 h-4 w-4" />Delete member
          </Button>
        )}
        <Button size="sm" variant="ghost" aria-expanded={showHistory} onClick={() => setShowHistory((v) => !v)}>
          <History className="mr-1 h-4 w-4" />History
        </Button>
      </div>
      {showHistory && <HistoryList userId={row.user_id} />}
    </li>
  );
}

export default function AdminAccountReviews() {
  const { data: rows, isLoading, error } = useAccountReviews();
  const act = useAccountAction();
  const [picked, setPicked] = useState<{ id: string; full_name: string | null } | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  const open = (p: Pending) => { setReason(""); setPending(p); };

  const confirm = async () => {
    if (!pending || !reason.trim()) return;
    setBusy(true);
    try {
      await act({ kind: pending.kind, userId: pending.userId, reason: reason.trim() });
      toast({ title: "Done", description: `${ACTION_TEXT[pending.kind].title}: ${pending.name}` });
      setPending(null);
      if (pending.kind === "under_review") setPicked(null);
    } catch (e) {
      toast({ title: "Not done", description: e instanceof Error ? e.message : "request failed", variant: "destructive" });
    }
    setBusy(false);
  };

  const underReview = rows?.filter((r) => r.state === "under_review") ?? [];
  const asked = rows?.filter((r) => r.state === "deletion_requested") ?? [];

  return (
    <div className="space-y-6 px-4 py-4 sm:px-0" data-testid="admin-account-reviews">
      <header>
        <h2 className="text-lg font-semibold">Account Review</h2>
        <p className="text-xs text-muted-foreground">
          Members under review can only look. Members who asked to be deleted wait for you; after 180 days with no answer they are deleted automatically.
        </p>
      </header>

      <section className="space-y-2 rounded-xl border border-border p-4" aria-labelledby="put-under-review">
        <h3 id="put-under-review" className="flex items-center gap-2 font-medium"><ShieldAlert className="h-4 w-4" />Put a member under review</h3>
        <ProfileTypeaheadPicker label="Member" hint="Search by name or e-mail. You give the reason on the next step." value={picked?.id ?? null} onChange={(p) => setPicked(p ? { id: p.id, full_name: p.full_name } : null)} />
        <Button size="sm" disabled={!picked} onClick={() => picked && open({ kind: "under_review", userId: picked.id, name: picked.full_name ?? "This member" })}>
          Put under review…
        </Button>
      </section>

      {isLoading && <Loader2 className="h-5 w-5 animate-spin" aria-label="Loading" />}
      {error && (
        <p className="text-sm text-muted-foreground">
          {/admin only/i.test((error as Error).message) ? "Admins only." : "Not available right now (the database may not have account review yet)."}
        </p>
      )}

      {rows && (
        <>
          <section className="space-y-2" aria-labelledby="asked-to-delete">
            <h3 id="asked-to-delete" className="font-medium">Asked to be deleted ({asked.length})</h3>
            {asked.length === 0 ? <p className="text-sm text-muted-foreground">Nobody is waiting.</p> : (
              <ul className="space-y-2">{asked.map((r) => <ReviewRow key={r.user_id} row={r} onAction={open} />)}</ul>
            )}
          </section>
          <section className="space-y-2" aria-labelledby="under-review">
            <h3 id="under-review" className="font-medium">Under review ({underReview.length})</h3>
            {underReview.length === 0 ? <p className="text-sm text-muted-foreground">Nobody is under review.</p> : (
              <ul className="space-y-2">{underReview.map((r) => <ReviewRow key={r.user_id} row={r} onAction={open} />)}</ul>
            )}
          </section>
        </>
      )}

      <AlertDialog open={!!pending} onOpenChange={(o) => { if (!o && !busy) setPending(null); }}>
        <AlertDialogContent>
          {pending && (
            <>
              <AlertDialogHeader>
                <AlertDialogTitle>{ACTION_TEXT[pending.kind].title}</AlertDialogTitle>
                <AlertDialogDescription>{ACTION_TEXT[pending.kind].body(pending.name)}</AlertDialogDescription>
              </AlertDialogHeader>
              <label className="space-y-1 text-sm">
                <span className="font-medium">Reason (required, kept 1 year)</span>
                <Textarea value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} rows={3} data-testid="account-action-reason" />
              </label>
              <AlertDialogFooter>
                <AlertDialogCancel disabled={busy}>Cancel</AlertDialogCancel>
                <AlertDialogAction
                  disabled={busy || !reason.trim()}
                  className={pending.kind === "delete" || pending.kind === "approve" ? "bg-destructive text-destructive-foreground hover:bg-destructive/90" : undefined}
                  onClick={(e) => { e.preventDefault(); void confirm(); }}
                >
                  {busy && <Loader2 className="mr-1 h-4 w-4 animate-spin" />}
                  {ACTION_TEXT[pending.kind].button}
                </AlertDialogAction>
              </AlertDialogFooter>
            </>
          )}
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

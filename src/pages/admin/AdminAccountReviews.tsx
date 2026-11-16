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
 * (see useAccountReviews); this page only collects them. The words, the reason
 * box and the history list are shared with Admin → Users (AccountActionDialog).
 */
import { useState } from "react";
import { Loader2, History, ShieldAlert, UserCheck, Trash2, PauseCircle, CheckCircle2 } from "lucide-react";
import ProfileTypeaheadPicker from "@/components/admin/ProfileTypeaheadPicker";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useAccountReviews, type AccountReviewRow } from "@/hooks/admin/useAccountReviews";
import {
  AccountActionDialog, AccountHistoryList, STATE_LABEL, fmtWhen as fmt,
  type PendingAccountAction,
} from "@/components/admin/AccountActionDialog";

export { ACTION_TEXT } from "@/components/admin/AccountActionDialog";

type Pending = { kind: PendingAccountAction["kind"]; userId: string; name: string };

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
      {showHistory && <AccountHistoryList userId={row.user_id} />}
    </li>
  );
}

export default function AdminAccountReviews() {
  const { data: rows, isLoading, error } = useAccountReviews();
  const [picked, setPicked] = useState<{ id: string; full_name: string | null } | null>(null);
  const [pending, setPending] = useState<PendingAccountAction | null>(null);

  const open = (p: Pending) => setPending({ kind: p.kind, userIds: [p.userId], name: p.name });

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

      <AccountActionDialog
        pending={pending}
        onClose={() => setPending(null)}
        onDone={(p) => { if (p.kind === "under_review") setPicked(null); }}
      />
    </div>
  );
}

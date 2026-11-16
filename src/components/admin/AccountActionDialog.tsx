/**
 * A4 account actions — the ONE place their words, their reason box and the
 * member's state history are drawn. Used by Admin → Account Review and by
 * Admin → Users; neither page keeps its own copy (Owner, 2026-11-04: central
 * control). The writes themselves are useAccountAction (hooks/admin/useAccountReviews).
 */
import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Textarea } from "@/components/ui/textarea";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { toast } from "@/hooks/core/use-toast";
import { useAccountStateHistory, useAccountAction, type AccountAction } from "@/hooks/admin/useAccountReviews";

/** One member (or several, for a bulk action) and what is about to happen to them. */
export type PendingAccountAction = { kind: AccountAction["kind"]; userIds: string[]; name: string };

export const fmtWhen = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : "—");

export const STATE_LABEL: Record<string, string> = {
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

export function AccountHistoryList({ userId }: { userId: string }) {
  const { data, isLoading, error } = useAccountStateHistory(userId);
  if (isLoading) return <Loader2 className="h-4 w-4 animate-spin" aria-label="Loading" />;
  if (error) return <p className="text-xs text-muted-foreground">History not available.</p>;
  if (!data?.length) return <p className="text-xs text-muted-foreground">No history.</p>;
  return (
    <ol className="space-y-1 text-xs" data-testid="account-history">
      {data.map((h, i) => (
        <li key={`${h.created_at}-${i}`} className="flex flex-wrap gap-x-2">
          <span className="tabular-nums text-muted-foreground">{fmtWhen(h.created_at)}</span>
          <span>{STATE_LABEL[h.from_state ?? "active"] ?? h.from_state} → {STATE_LABEL[h.to_state] ?? h.to_state}</span>
          <span className="text-muted-foreground">by {h.actor_name ?? "system"}</span>
          {h.reason && <span className="w-full pl-2 text-muted-foreground">“{h.reason}”</span>}
        </li>
      ))}
    </ol>
  );
}

/**
 * The reason box + confirm for any A4 action. A bulk action runs the same rpc
 * once per member with the same reason; the toast says how many went through.
 */
export function AccountActionDialog({
  pending, onClose, onDone,
}: { pending: PendingAccountAction | null; onClose: () => void; onDone?: (p: PendingAccountAction) => void }) {
  const act = useAccountAction();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  const confirm = async () => {
    if (!pending || !reason.trim()) return;
    setBusy(true);
    let ok = 0;
    let lastError = "";
    for (const userId of pending.userIds) {
      try {
        await act({ kind: pending.kind, userId, reason: reason.trim() });
        ok++;
      } catch (e) {
        lastError = e instanceof Error ? e.message : "request failed";
      }
    }
    setBusy(false);
    if (ok > 0) {
      toast({ title: "Done", description: `${ACTION_TEXT[pending.kind].title}: ${pending.name}${pending.userIds.length > 1 ? ` (${ok} of ${pending.userIds.length})` : ""}` });
      setReason("");
      onDone?.(pending);
      onClose();
    }
    if (lastError) toast({ title: "Not done", description: lastError, variant: "destructive" });
  };

  return (
    <AlertDialog open={!!pending} onOpenChange={(o) => { if (!o && !busy) { setReason(""); onClose(); } }}>
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
  );
}

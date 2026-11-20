/**
 * M8b · the ONE reason box for Admin → Messages. Every change to the messages
 * switch, a member's rules, the word list, a held message — and every reading of
 * a chat — needs a reason (1–500 characters). The database checks it again and
 * writes it to the log; this dialog only collects it and shows the server's own
 * words if it refuses.
 */
import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Textarea } from "@/components/ui/textarea";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { toast } from "@/hooks/core/use-toast";

export interface ReasonRequest {
  title: string;
  body: string;
  button: string;
  destructive?: boolean;
  /** Runs with the trimmed reason. Throw to keep the box open and show the words. */
  run: (reason: string) => Promise<void>;
  /** Shown as a toast when run() returns. */
  doneText?: string;
}

export default function ReasonDialog({ request, onClose }: { request: ReasonRequest | null; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  const confirm = async () => {
    if (!request || !reason.trim() || busy) return;
    setBusy(true);
    try {
      await request.run(reason.trim());
      if (request.doneText) toast({ title: "Done", description: request.doneText });
      setReason("");
      onClose();
    } catch (e) {
      toast({ title: "Not done", description: e instanceof Error ? e.message : "request failed", variant: "destructive" });
    } finally {
      setBusy(false);
    }
  };

  return (
    <AlertDialog open={!!request} onOpenChange={(o) => { if (!o && !busy) { setReason(""); onClose(); } }}>
      <AlertDialogContent>
        {request && (
          <>
            <AlertDialogHeader>
              <AlertDialogTitle>{request.title}</AlertDialogTitle>
              <AlertDialogDescription>{request.body}</AlertDialogDescription>
            </AlertDialogHeader>
            <label className="space-y-1 text-sm">
              <span className="font-medium">Reason (required, kept 1 year in the log)</span>
              <Textarea value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} rows={3} data-testid="messages-reason" />
            </label>
            <AlertDialogFooter>
              <AlertDialogCancel disabled={busy}>Cancel</AlertDialogCancel>
              <AlertDialogAction
                disabled={busy || !reason.trim()}
                className={request.destructive ? "bg-destructive text-destructive-foreground hover:bg-destructive/90" : undefined}
                onClick={(e) => { e.preventDefault(); void confirm(); }}
              >
                {busy && <Loader2 className="mr-1 h-4 w-4 animate-spin" aria-hidden="true" />}
                {request.button}
              </AlertDialogAction>
            </AlertDialogFooter>
          </>
        )}
      </AlertDialogContent>
    </AlertDialog>
  );
}

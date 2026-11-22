/**
 * Messages · "Report this chat". A member tells the site team about a chat they are in:
 * pick a reason, add a note if they like. One open report per member per chat (the server
 * keeps it that way). Only reported chats reach the admins — there is no approval queue.
 */
import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { toast } from "@/hooks/core/use-toast";
import { useT } from "@/i18n/I18nContext";
import { reportConversation, type ReportReason } from "@/lib/messages/api";

/** Opened from the chat's ⋯ menu ("Report this chat") — no button of its own in the header (Owner 22 Nov: one menu, not three icons). */
export default function ReportChat({ conversationId, open, onOpenChange }: { conversationId: string; open: boolean; onOpenChange: (open: boolean) => void }) {
  const t = useT();
  const setOpen = onOpenChange;
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  const reasons: { key: ReportReason; label: string }[] = [
    { key: "spam", label: t("messages.report.spam", "Spam or unwanted promotion") },
    { key: "abuse", label: t("messages.report.abuse", "Abuse or harassment") },
    { key: "threat", label: t("messages.report.threat", "Threats") },
    { key: "nudity", label: t("messages.report.nudity", "Nudity or sexual content") },
    { key: "other", label: t("messages.report.other", "Something else") },
  ];

  const send = async () => {
    if (!reason || busy) return;
    setBusy(true);
    try {
      await reportConversation(conversationId, reason, note);
      toast({ title: t("messages.report.sent", "Thank you"), description: t("messages.report.sentBody", "Our team will look at this chat.") });
      setOpen(false); setReason(null); setNote("");
    } catch {
      toast({ title: t("messages.report.failed", "Could not send the report"), description: t("messages.report.tryAgain", "Please try again."), variant: "destructive" });
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Dialog open={open} onOpenChange={(o) => { if (!busy) setOpen(o); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("messages.report.title", "Report this chat")}</DialogTitle>
            <DialogDescription>{t("messages.report.body", "Tell us what is wrong. The other person is not told.")}</DialogDescription>
          </DialogHeader>
          <div role="radiogroup" aria-label={t("messages.report.title", "Report this chat")} className="space-y-1.5">
            {reasons.map((r) => (
              <button key={r.key} type="button" role="radio" aria-checked={reason === r.key} onClick={() => setReason(r.key)}
                className={`flex min-h-11 w-full items-center rounded-xl border px-3 text-left text-sm ${reason === r.key ? "border-primary bg-primary/5 font-semibold" : "border-border hover:bg-muted/40"}`}>
                {r.label}
              </button>
            ))}
          </div>
          <Textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} rows={2}
            placeholder={t("messages.report.note", "Add a note (optional)")} aria-label={t("messages.report.note", "Add a note (optional)")} />
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>{t("common.cancel", "Cancel")}</Button>
            <Button onClick={() => void send()} disabled={!reason || busy}>
              {busy && <Loader2 className="mr-1 h-4 w-4 animate-spin" aria-hidden="true" />}{t("messages.report.send", "Send report")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

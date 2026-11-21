/**
 * Admin → Messages: "Export chat" — the whole chat as one JSON file, for a legal request or a safety case (M29, SQL 3800).
 * The server checks the admin and records each export (who, which chat, when). Nothing is shown on screen beyond the file.
 */
import { useState } from "react";
import { Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { toast } from "@/hooks/core/use-toast";
import { adminMessageCall } from "@/hooks/admin/useAdminMessages";

export default function ExportChatButton({ userId, conversationId }: { userId: string; conversationId: string }) {
  const [busy, setBusy] = useState(false);
  const run = async () => {
    setBusy(true);
    try {
      const data = await adminMessageCall("admin_message_export", { _user: userId, _conversation: conversationId });
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
      const href = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = href;
      a.download = `chat-${conversationId.slice(0, 8)}-${new Date().toISOString().slice(0, 10)}.json`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(href), 10_000);
      const n = typeof data === "object" && data !== null ? Number((data as Record<string, unknown>).message_count ?? 0) : 0;
      toast({ title: "Chat exported", description: `${n.toLocaleString()} message${n === 1 ? "" : "s"} saved to a file. This export is recorded.` });
    } catch (e) {
      toast({ title: "Not exported", description: e instanceof Error ? e.message : "request failed", variant: "destructive" });
    } finally { setBusy(false); }
  };
  return (
    <Button variant="outline" size="sm" onClick={() => void run()} disabled={busy} data-testid="export-chat"><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export chat</Button>
  );
}

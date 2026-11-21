/**
 * M8b · the logged chat viewer. Opening a chat asks for a reason FIRST; the server
 * writes the log row (who, when, why) before it returns one message — no reason,
 * no read. Photos open through a 10-minute window the logged read
 * creates (message_photo_visible); after that the links stop working.
 */
import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import OptimizedImage from "@/components/OptimizedImage";
import { signedPhotoUrl } from "@/lib/messages/api";
import ReasonDialog, { type ReasonRequest } from "./ReasonDialog";
import { adminMessageCall, parseViewedChat, type ViewedChat } from "@/hooks/admin/useAdminMessages";

const when = (iso: string) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};

function AdminPhoto({ path, width, height }: { path: string; width: number | null; height: number | null }) {
  const { data: url, isLoading } = useQuery({ queryKey: ["messages", "admin-photo", path], queryFn: () => signedPhotoUrl(path), staleTime: 4 * 60_000, retry: false });
  const ratio = width && height ? `${width} / ${height}` : "1 / 1";
  return (
    <div className="mt-1 w-40 overflow-hidden rounded-md bg-muted" style={{ aspectRatio: ratio }}>
      {url ? <OptimizedImage src={url} alt="Photo in this chat" loading="lazy" className="h-full w-full object-cover" />
        : <div className="grid h-full w-full place-items-center p-2 text-center text-[11px] text-muted-foreground">{isLoading ? "Loading…" : "Link expired — read the chat again"}</div>}
    </div>
  );
}

export default function ChatReader({ conversationId, onClose }: { conversationId: string; onClose: () => void }) {
  const [chat, setChat] = useState<ViewedChat | null>(null);
  const [request, setRequest] = useState<ReasonRequest | null>(null);
  const got = useRef(false);

  const readChat = async (reason: string) => {
    const data = await adminMessageCall("admin_read_conversation", { _conversation: conversationId, _reason: reason, _before_id: null, _limit: 100 });
    const v = parseViewedChat(data);
    if (!v) throw new Error("Could not read this chat");
    got.current = true;
    setChat(v);
    return reason;
  };

  // the reason box opens first; closing it without reading closes the reader
  useEffect(() => {
    got.current = false;
    setChat(null);
    setRequest({
      title: "Read this chat?",
      body: "Opening a chat is logged: who opened it, when, and your reason. The members can be shown that an admin looked.",
      button: "Open and log",
      run: async (reason) => { await readChat(reason); },
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversationId]);

  const nameOf = (id: string) => {
    const m = chat?.members.find((x) => x.user_id === id);
    return m?.full_name || (m?.username ? `@${m.username}` : id.slice(0, 8));
  };

  return (
    <>
      <ReasonDialog request={request} onClose={() => { setRequest(null); if (!got.current) onClose(); }} />
      <Dialog open={!!chat} onOpenChange={(o) => { if (!o) onClose(); }}>
        <DialogContent className="max-h-[85vh] overflow-hidden sm:max-w-xl" data-testid="messages-chat-reader">
          <DialogHeader>
            <DialogTitle>{chat ? chat.members.map((m) => nameOf(m.user_id)).join(" · ") : "Chat"}</DialogTitle>
            <DialogDescription>This reading is logged. Newest message at the bottom.</DialogDescription>
          </DialogHeader>
          <div className="max-h-[60vh] space-y-2 overflow-y-auto pr-1">
            {chat && chat.messages.length === 0 && <p className="text-sm text-muted-foreground">No messages in this chat.</p>}
            {chat && [...chat.messages].reverse().map((m) => (
              <div key={m.id} className="rounded-lg border border-border p-2 text-sm" data-testid="messages-reader-row">
                <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                  <b className="text-foreground">{nameOf(m.sender_id)}</b><span>{when(m.created_at)}</span>
                  {m.status === "held" && <Badge variant="outline">Held</Badge>}
                  {m.status === "rejected" && <Badge variant="destructive">Rejected</Badge>}
                </div>
                {m.body && <p className="mt-1 whitespace-pre-wrap break-words">{m.body}</p>}
                {m.photos.map((p) => <AdminPhoto key={p.path} {...p} />)}
              </div>
            ))}
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

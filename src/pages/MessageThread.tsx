/**
 * /messages/:conversationId and /messages/with/:userId — one private chat.
 * The server decides who may send; the composer only shows what it answers. Messages are
 * plain text (a link is not made clickable). A retry of the same text reuses its message id,
 * so the server stores it once. Photos are re-encoded to WebP in the browser first.
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, ImagePlus, Loader2, Send } from "lucide-react";
import { useT } from "@/i18n/I18nContext";
import { useAuth } from "@/hooks/core/useAuth";
import { goBackOrFeed } from "@/lib/navigationContract";
import { inAppHistoryDepth } from "@/hooks/core/useAndroidBackButton";
import {
  newClientMsgId, useConversationActions, useConversations, useMessagingAllowed, useSendMessage, useSendPhotos, useThread,
} from "@/hooks/messages/useMessages";
import { fetchPerson, MessageSendError, type MessagePerson } from "@/lib/messages/api";
import { prepareAndUploadPhoto } from "@/lib/messages/photoUpload";
import { HelplineCard, MessageBubble, PersonAvatar, headingFont, refusalText } from "@/components/messages/MessageParts";

const MAX_PHOTOS = 10;

export default function MessageThread() {
  const t = useT();
  const navigate = useNavigate();
  const { user, loading: authLoading } = useAuth();
  useEffect(() => { if (!authLoading && !user) navigate("/login", { replace: true }); }, [authLoading, user, navigate]);
  const { conversationId, userId } = useParams<{ conversationId?: string; userId?: string }>();
  const allowed = useMessagingAllowed();
  const inbox = useConversations("inbox");
  const requests = useConversations("requests");
  const known = useMemo(
    () => [...(inbox.data ?? []), ...(requests.data ?? [])],
    [inbox.data, requests.data],
  );
  const existing = userId ? known.find((c) => c.kind === "direct" && c.other?.userId === userId) : undefined;
  const convId = conversationId ?? existing?.conversationId ?? null;
  const entry = known.find((c) => c.conversationId === convId);
  const inRequests = entry?.folder === "requests";

  // /messages/with/:userId → the chat that already exists, else a new one to start
  useEffect(() => {
    if (userId && existing) navigate(`/messages/${existing.conversationId}`, { replace: true });
  }, [userId, existing, navigate]);

  const thread = useThread(convId);
  const messages = useMemo(() => [...(thread.data ?? [])].reverse(), [thread.data]);
  const otherId = entry?.other?.userId ?? userId ?? messages.find((m) => m.senderId !== user?.id)?.senderId ?? null;
  const { data: fetched } = useQuery<MessagePerson | null>({
    queryKey: ["messages", "person", otherId],
    queryFn: () => fetchPerson(otherId as string),
    enabled: !!otherId && !entry?.other,
    staleTime: 5 * 60_000,
  });
  const person = entry?.other ?? fetched ?? null;

  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [help, setHelp] = useState(false);
  const [uploading, setUploading] = useState(false);
  const attempt = useRef<{ body: string; id: string } | null>(null);
  const send = useSendMessage();
  const sendPhotos = useSendPhotos();
  const { accept, decline, markRead } = useConversationActions();
  const fileRef = useRef<HTMLInputElement>(null);
  const endRef = useRef<HTMLDivElement>(null);
  const lastMarked = useRef<number | null>(null);

  const newestId = messages.length ? messages[messages.length - 1].id : null;
  useEffect(() => { endRef.current?.scrollIntoView({ block: "end" }); }, [newestId, help]);
  useEffect(() => {
    if (convId && newestId !== null && lastMarked.current !== newestId) {
      lastMarked.current = newestId;
      markRead.mutate(convId);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- markRead is a stable mutation object per render; the guard above is the dedupe
  }, [convId, newestId]);

  const busy = send.isPending || sendPhotos.isPending || uploading;

  const onSend = async () => {
    const body = text.trim();
    if (!body || !otherId || busy) return;
    setError(null);
    const id = attempt.current?.body === body ? attempt.current.id : newClientMsgId();
    attempt.current = { body, id };
    try {
      const r = await send.mutateAsync({ to: otherId, body, clientMsgId: id });
      attempt.current = null;
      setText("");
      if (r.help) setHelp(true);
      if (!convId) navigate(`/messages/${r.conversationId}`, { replace: true });
    } catch (e) {
      setError(refusalText(e instanceof MessageSendError ? e.refusal : "unknown"));
    }
  };

  const onPickPhotos = async (files: FileList | null) => {
    if (!files || files.length === 0 || !otherId || !user || busy) return;
    setError(null);
    setUploading(true);
    try {
      const picked = Array.from(files).slice(0, MAX_PHOTOS);
      const uploaded = [];
      for (const f of picked) uploaded.push(await prepareAndUploadPhoto(f, user.id));
      const r = await sendPhotos.mutateAsync({ to: otherId, caption: text.trim(), clientMsgId: newClientMsgId(), photos: uploaded });
      setText("");
      if (r.help) setHelp(true);
      if (!convId) navigate(`/messages/${r.conversationId}`, { replace: true });
    } catch (e) {
      setError(refusalText(e instanceof MessageSendError ? e.refusal : "bad_photo"));
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  return (
    <div className="mx-auto flex h-[calc(100dvh-8rem)] max-w-2xl flex-col">
      <div className="flex items-center gap-3 border-b border-border px-4 py-3">
        <button type="button" onClick={() => goBackOrFeed(navigate, inAppHistoryDepth())} aria-label={t("common.back", "Back")} className="p-1 -ml-1 tap-44 text-foreground hover:text-primary transition-colors">
          <ArrowLeft className="h-5 w-5" />
        </button>
        <PersonAvatar person={person} size={36} />
        <h1 className="min-w-0 flex-1 truncate text-base font-semibold" style={headingFont}>{person?.fullName || t("messages.chat", "Chat")}</h1>
      </div>

      {inRequests && convId && (
        <div className="flex items-center gap-2 border-b border-border bg-muted/40 px-4 py-2 text-sm" data-testid="request-bar">
          <span className="flex-1 text-muted-foreground">{t("messages.request.note", "You don't follow this person. Accept to move this chat to your Messages.")}</span>
          <button type="button" onClick={() => accept.mutate(convId)} className="rounded-lg bg-primary px-3 py-1.5 text-xs font-semibold text-primary-foreground">{t("messages.request.accept", "Accept")}</button>
          <button type="button" onClick={() => decline.mutate(convId, { onSuccess: () => navigate("/messages", { replace: true }) })} className="rounded-lg bg-muted px-3 py-1.5 text-xs font-semibold">{t("messages.request.decline", "Decline")}</button>
        </div>
      )}

      <div className="flex-1 space-y-1.5 overflow-y-auto py-3" aria-live="polite">
        {thread.isLoading && convId && <p className="py-10 text-center text-sm text-muted-foreground">{t("common.loading", "Loading…")}</p>}
        {!thread.isLoading && messages.length === 0 && (
          <p className="px-6 py-16 text-center text-sm text-muted-foreground">{t("messages.thread.empty", "Say hello 👋")}</p>
        )}
        {messages.map((m) => <MessageBubble key={m.id} m={m} mine={m.senderId === user?.id} />)}
        {help && <HelplineCard onClose={() => setHelp(false)} />}
        <div ref={endRef} />
      </div>

      {!allowed ? (
        <p className="border-t border-border px-4 py-3 text-center text-sm text-muted-foreground" data-testid="send-off-note">
          {t("messages.sendOff", "Sending messages isn't available for your account. You can still read your chats.")}
        </p>
      ) : (
        <div className="border-t border-border px-3 py-2">
          {error && <p role="alert" className="mb-1.5 px-1 text-xs text-destructive">{error}</p>}
          <div className="flex items-end gap-2">
            <input ref={fileRef} type="file" accept="image/jpeg,image/png,image/webp,image/heic" multiple hidden onChange={(e) => void onPickPhotos(e.target.files)} />
            <button type="button" onClick={() => fileRef.current?.click()} disabled={busy} aria-label={t("messages.addPhoto", "Add photo")} className="grid h-11 w-11 shrink-0 place-items-center rounded-full text-muted-foreground hover:text-primary disabled:opacity-50">
              {uploading ? <Loader2 className="h-5 w-5 animate-spin" /> : <ImagePlus className="h-5 w-5" />}
            </button>
            <textarea
              value={text}
              onChange={(e) => setText(e.target.value.slice(0, 4000))}
              rows={1}
              placeholder={t("messages.placeholder", "Message…")}
              aria-label={t("messages.placeholder", "Message…")}
              className="max-h-32 min-h-[44px] flex-1 resize-none rounded-2xl border border-border bg-background px-3.5 py-2.5 text-[15px] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
              onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void onSend(); } }}
            />
            <button type="button" onClick={() => void onSend()} disabled={busy || !text.trim()} aria-label={t("messages.send", "Send")} className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground disabled:opacity-50">
              {send.isPending ? <Loader2 className="h-5 w-5 animate-spin" /> : <Send className="h-5 w-5" />}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

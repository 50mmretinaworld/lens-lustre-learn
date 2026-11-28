/**
 * Messages · one chat: header, request bar, day chips + grouped bubbles, composer.
 * The server decides who may send; the composer only shows what it answers. Plain text only. A retry of the
 * same text reuses its message id, so the server stores it once. Photos are re-encoded to WebP in the browser first.
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import ProfileLink from "@/components/ProfileLink";
import { useQuery } from "@tanstack/react-query";
import { Clock, Copy, ImagePlus, Loader2, Reply, Search, SendHorizontal, Smile, X } from "lucide-react";
import { useIsOfficial } from "@/hooks/messages/useIsOfficial";
import { motion } from "framer-motion";
import { useT } from "@/i18n/I18nContext";
import { useAuth } from "@/hooks/core/useAuth";
import {
  newClientMsgId, useConversationActions, useConversations, useMessagingAllowed, useSendMessage, useSendPhotos, useThread,
} from "@/hooks/messages/useMessages";
import { fetchPerson, fetchThread, fetchViewThread, MessageSendError, type MessagePerson, type ThreadMessage } from "@/lib/messages/api";
import { EMOJI_SETS } from "@/lib/messages/emoji";
import { groupChat } from "@/lib/messages/format";
import { mergeNewest, mergeOlder } from "@/lib/messages/history";
import { suggestReplies } from "@/lib/messages/suggest";
import { prepareAndUploadPhoto } from "@/lib/messages/photoUpload";
import { useChatLive } from "@/hooks/messages/useChatLive";
import { HelplineCard, MessageBubble, PersonAvatar, TypingDots, refusalText } from "@/components/messages/MessageParts";
import { ChatHeader, DaySeparator, HeaderTitle, MSG } from "@/components/messages/ui";
import ReportChat from "@/components/messages/ReportChat";
import ChatMenu from "@/components/messages/ChatMenu";
import AutoBadge from "@/components/AutoBadge";
import { usePeerStatus } from "@/hooks/messages/usePeerStatus";
import { useMessageQueue } from "@/hooks/messages/useMessageQueue";
import { isOfflineFailure, queueMessage } from "@/lib/messages/queue";
import { useViewAs } from "@/components/messages/viewAs";

const MAX_PHOTOS = 10;

export default function ChatPane({ conversationId, userId, onBack }: { conversationId: string | null; userId: string | null; onBack: () => void }) {
  const t = useT();
  const navigate = useNavigate();
  const { user } = useAuth();
  const viewAs = useViewAs();                     // admin viewing a member's box: read-only, that member is "me"
  const meId = viewAs?.userId ?? user?.id;
  const allowed = useMessagingAllowed();
  const inbox = useConversations("inbox");
  const requests = useConversations("requests");
  const known = useMemo(() => [...(inbox.data ?? []), ...(requests.data ?? [])], [inbox.data, requests.data]);
  const existing = userId ? known.find((c) => c.kind === "direct" && c.other?.userId === userId) : undefined;
  const convId = conversationId ?? existing?.conversationId ?? null;
  const entry = known.find((c) => c.conversationId === convId);
  const inRequests = entry?.folder === "requests";

  // /messages/with/:userId → the chat that already exists, else a new one to start
  useEffect(() => {
    if (userId && existing) navigate(`/messages/${existing.conversationId}`, { replace: true });
  }, [userId, existing, navigate]);

  const thread = useThread(convId);
  // OLDER MESSAGES (Owner 22 Nov 2026): the chat used to show only its newest 50. Scrolling to the top — or tapping a quote
  // whose original is older — now loads the page before, 50 at a time, until the start of the chat.
  // ONE LIST (Owner 23 Nov: "200 sent, only a few showing, scrolling does not show them"): every page is merged into
  // one oldest-first list (src/lib/messages/history.ts). A fresh newest page that no longer reaches back to what the
  // screen holds leaves a hole; it is closed by loading the pages before it (kept open across refreshes until closed).
  const PAGE = 50;
  const [history, setHistory] = useState<ThreadMessage[]>([]);
  const historyRef = useRef<ThreadMessage[]>([]);
  const putHistory = (h: ThreadMessage[]) => { historyRef.current = h; setHistory(h); };
  const openGap = useRef<{ before: number; heldMax: number } | null>(null);
  const [noMore, setNoMore] = useState(false);
  const loadingOlder = useRef(false);
  useEffect(() => { putHistory([]); openGap.current = null; setNoMore(false); }, [convId]);
  const fetchBefore = (id: number) =>
    (viewAs ? fetchViewThread(viewAs.userId, convId as string, id, PAGE) : fetchThread(convId as string, id, PAGE)).then((p) => [...p].reverse());
  useEffect(() => {
    if (!convId || !thread.data) return;
    const prev = historyRef.current;
    const page = [...thread.data].reverse();
    const { merged, gapBefore } = mergeNewest(prev, page, page.length >= PAGE);
    putHistory(merged);
    if (gapBefore !== null && !openGap.current) {
      openGap.current = { before: gapBefore, heldMax: prev.filter((m) => m.id < gapBefore).at(-1)?.id ?? 0 };
    }
    if (!openGap.current) return;
    let cancelled = false;
    void (async () => {
      for (let i = 0; i < 20 && !cancelled && openGap.current; i++) {
        const gap = openGap.current;
        let rows: ThreadMessage[];
        try { rows = await fetchBefore(gap.before); } catch { return; }   // poor network: retried on the next refresh
        if (cancelled) return;
        putHistory(mergeOlder(historyRef.current, rows));
        if (rows.length < PAGE || rows[0].id <= gap.heldMax) { openGap.current = null; return; }
        openGap.current = { ...gap, before: rows[0].id };
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- runs when a fresh newest page arrives
  }, [thread.data, convId]);
  const oldestFirst = useMemo(
    () => (history.length ? history : [...(thread.data ?? [])].reverse()),
    [history, thread.data],
  );
  const loadOlder = async (): Promise<boolean> => {
    if (!convId || noMore || loadingOlder.current || oldestFirst.length < PAGE) return false;
    loadingOlder.current = true;
    try {
      const page = await fetchBefore(oldestFirst[0].id);
      if (page.length < PAGE) setNoMore(true);
      if (page.length > 0) putHistory(mergeOlder(historyRef.current.length ? historyRef.current : oldestFirst, page));
      return page.length > 0;
    } catch {
      return false;
    } finally {
      loadingOlder.current = false;
    }
  };
  const [searching, setSearching] = useState(false);
  const [reporting, setReporting] = useState(false);
  const [searchText, setSearchText] = useState("");
  const needle = searchText.trim().toLowerCase();
  const shown = useMemo(() => (needle ? oldestFirst.filter((m) => m.body.toLowerCase().includes(needle)) : oldestFirst), [oldestFirst, needle]);
  const items = useMemo(() => groupChat(shown), [shown]);
  const otherId = entry?.other?.userId ?? userId ?? oldestFirst.find((m) => m.senderId !== meId)?.senderId ?? null;
  const { data: fetched } = useQuery<MessagePerson | null>({
    queryKey: ["messages", "person", otherId],
    queryFn: () => fetchPerson(otherId as string),
    enabled: !!otherId && !entry?.other,
    staleTime: 5 * 60_000,
  });
  const person = entry?.other ?? fetched ?? null;
  const official = useIsOfficial(otherId);        // 50mm Retina World: never blocked or reported, no "Active … ago", no chips
  const [menuFor, setMenuFor] = useState<ThreadMessage | null>(null);   // the message held down (its Reply / Copy menu)

  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [help, setHelp] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [picker, setPicker] = useState(false);
  const [pickerTab, setPickerTab] = useState(0);
  const attempt = useRef<{ body: string; id: string } | null>(null);
  const send = useSendMessage();
  const sendPhotos = useSendPhotos();
  const { accept, decline, markRead } = useConversationActions();
  const fileRef = useRef<HTMLInputElement>(null);
  const endRef = useRef<HTMLDivElement>(null);
  const areaRef = useRef<HTMLTextAreaElement>(null);
  const lastMarked = useRef<number | null>(null);
  const [replyTo, setReplyTo] = useState<ThreadMessage | null>(null);   // the message the next send answers
  useEffect(() => { setReplyTo(null); }, [convId]);
  const quoteName = (senderId: string) => (senderId === meId ? "You" : person?.fullName || "Member");
  /** Tap a quote: scroll to the original and flash it — loading older pages first when it is not on screen yet. */
  const pendingJump = useRef<number | null>(null);
  const flash = (el: HTMLElement) => {
    el.scrollIntoView({ block: "center", behavior: "smooth" });
    el.classList.add("bg-primary/15");
    window.setTimeout(() => el.classList.remove("bg-primary/15"), 1400);
  };
  const jumpTo = (id: number) => {
    const el = document.getElementById(`msg-${id}`);
    if (el) { flash(el); return; }
    pendingJump.current = id;
    void loadOlder();
  };
  // after an older page arrives: either the quoted message is there now, or load one more page (stops at the chat's start)
  useEffect(() => {
    const id = pendingJump.current;
    if (id === null) return;
    const el = document.getElementById(`msg-${id}`);
    if (el) { pendingJump.current = null; flash(el); return; }
    if (noMore) { pendingJump.current = null; return; }
    void loadOlder();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- runs when a page has been added
  }, [history, noMore]);
  /** Scrolled to the top: the page before, keeping the reader's place. */
  const scrollRef = useRef<HTMLDivElement>(null);
  const onThreadScroll = () => {
    const box = scrollRef.current;
    if (!box || box.scrollTop > 80 || noMore || loadingOlder.current) return;
    const before = box.scrollHeight;
    void loadOlder().then((added) => {
      if (!added) return;
      window.requestAnimationFrame(() => { if (scrollRef.current) scrollRef.current.scrollTop += scrollRef.current.scrollHeight - before; });
    });
  };
  const queued = useMessageQueue(viewAs ? undefined : user?.id, otherId);   // texts written with no network, waiting to be sent
  const live = useChatLive(convId, user?.id, !viewAs);   // typing dots + instant refresh; an admin's read-only view never joins

  const newestId = oldestFirst.length ? oldestFirst[oldestFirst.length - 1].id : null;
  useEffect(() => { endRef.current?.scrollIntoView({ block: "end" }); }, [newestId, help, convId]);
  useEffect(() => {
    if (!viewAs && !inRequests && convId && newestId !== null && lastMarked.current !== newestId) {
      lastMarked.current = newestId;
      markRead.mutate(convId, { onSuccess: () => live.ping() });   // the sender's ticks turn blue at once
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- markRead is a stable mutation object per render; the guard above is the dedupe
  }, [convId, newestId, inRequests]);
  // the box grows with the text, up to about five lines
  useEffect(() => {
    const el = areaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 128)}px`;
  }, [text]);

  const busy = send.isPending || sendPhotos.isPending || uploading;

  /** Sends `raw` (the box, or a tapped suggestion). Only the box is cleared afterwards. */
  const sendText = async (raw: string, fromBox: boolean) => {
    const body = raw.trim();
    if (!body || !otherId || busy) return;
    setError(null);
    const id = attempt.current?.body === body ? attempt.current.id : newClientMsgId();
    attempt.current = { body, id };
    try {
      const r = await send.mutateAsync({ to: otherId, body, clientMsgId: id, replyTo: replyTo?.id ?? null });
      attempt.current = null;
      live.ping();
      setReplyTo(null);
      if (fromBox) setText("");
      setPicker(false);
      if (r.help) setHelp(true);
      if (!convId) navigate(`/messages/${r.conversationId}`, { replace: true });
    } catch (e) {
      // no network: keep the message on this device and send it, once, when the network is back (same id = never twice)
      if (isOfflineFailure(e) && meId && otherId && !viewAs && queueMessage({ id, userId: meId, to: otherId, body, replyTo: replyTo?.id ?? null })) {
        attempt.current = null;
        if (fromBox) setText("");
        setReplyTo(null);
        setPicker(false);
        return;
      }
      setError(refusalText(e instanceof MessageSendError ? e.refusal : "unknown"));
    }
  };
  const onSend = () => sendText(text, true);

  // smart replies: shown only when the last message in this chat is the other person's, and sending is allowed
  const lastMsg = oldestFirst.length ? oldestFirst[oldestFirst.length - 1] : null;
  // …and never in the official chat, and gone as soon as the member starts typing
  const chips = allowed && !viewAs && !official && !text && lastMsg && lastMsg.senderId !== meId && !inRequests ? suggestReplies(lastMsg) : [];
  // Instagram: one status line, under MY LAST message only — "Seen" / "Delivered" / "Sent"
  const lastMineId = useMemo(() => {
    for (let i = oldestFirst.length - 1; i >= 0; i--) if (oldestFirst[i].senderId === meId && oldestFirst[i].status === "sent") return oldestFirst[i].id;
    return null;
  }, [oldestFirst, meId]);
  const statusOf = (msg: ThreadMessage) => (msg.id !== lastMineId ? null
    : msg.tick === "read" ? t("messages.status.seen", "Seen") : msg.tick === "delivered" ? t("messages.status.delivered", "Delivered") : t("messages.status.sent", "Sent"));
  // a reply to a photo shows that photo small on the quote (WhatsApp), when the original is loaded
  const photoById = useMemo(() => new Map(oldestFirst.filter((x) => x.photos.length > 0).map((x) => [x.id, x.photos[0].path])), [oldestFirst]);

  const addEmoji = (e: string) => {
    const el = areaRef.current;
    const at = el ? el.selectionStart ?? text.length : text.length;
    const to = el ? el.selectionEnd ?? at : at;
    const next = (text.slice(0, at) + e + text.slice(to)).slice(0, 4000);
    setText(next);
    window.requestAnimationFrame(() => { el?.focus(); el?.setSelectionRange(at + e.length, at + e.length); });
  };

  const onPickPhotos = async (files: FileList | null) => {
    if (!files || files.length === 0 || !otherId || !user || busy) return;
    setError(null);
    setUploading(true);
    try {
      const uploaded = [];
      for (const f of Array.from(files).slice(0, MAX_PHOTOS)) uploaded.push(await prepareAndUploadPhoto(f, user.id));
      const r = await sendPhotos.mutateAsync({ to: otherId, caption: text.trim(), clientMsgId: newClientMsgId(), photos: uploaded, replyTo: replyTo?.id ?? null });
      setText("");
      setReplyTo(null);
      live.ping();
      if (r.help) setHelp(true);
      if (!convId) navigate(`/messages/${r.conversationId}`, { replace: true });
    } catch (e) {
      setError(refusalText(e instanceof MessageSendError ? e.refusal : e instanceof Error && e.message === "upload-failed" ? "upload_failed" : "bad_photo"));
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  const name = person?.fullName || t("messages.chat", "Chat");
  const peer = usePeerStatus(otherId, !viewAs);   // "Active now" / "Active 12 m ago" (Owner 21 Nov, Meta style)

  return (
    <div className="flex h-full min-h-0 flex-col bg-background">
      <ChatHeader
        onBack={onBack}
        actions={convId && !viewAs ? (
          <>
            <ChatMenu conversationId={convId} otherId={otherId} muted={!!entry?.muted} onSearch={() => setSearching(true)} onReport={official ? undefined : () => setReporting(true)} />
            {!official && <ReportChat conversationId={convId} open={reporting} onOpenChange={setReporting} />}
          </>
        ) : undefined}
      >
        {/* Owner 21 Nov: tapping the picture or the name opens that member's profile */}
        {(() => {
          // the official account shows its @handle only (no "Active … ago"); a member: "Active now" or "@handle" — never a dangling "·"
          const presence = official ? null : peer.text;
          const sub = (presence || person?.username)
            ? <span data-testid="peer-status">{presence ? <span className={peer.online ? "text-green-500" : ""}>{presence}</span> : `@${person?.username}`}</span>
            : undefined;
          const head = (
            <>
              <PersonAvatar person={person} size={34} showOnline />
              <HeaderTitle title={name} sub={sub} badge={otherId ? <AutoBadge userId={otherId} only="verified" /> : undefined} />
            </>
          );
          return otherId
            ? <ProfileLink userId={otherId} handle={person?.username} aria-label={name} data-testid="chat-header-profile" className="flex min-w-0 flex-1 items-center gap-2.5 text-left hover:opacity-90">{head}</ProfileLink>
            : <div className="flex min-w-0 flex-1 items-center gap-2.5">{head}</div>;
        })()}
      </ChatHeader>

      {searching && (
        <div data-testid="chat-search" className="flex h-11 shrink-0 items-center gap-2 border-b border-border bg-background px-4">
          <Search aria-hidden className="h-4 w-4 shrink-0 text-muted-foreground" />
          <input
            autoFocus value={searchText} onChange={(e) => setSearchText(e.target.value)} maxLength={100}
            placeholder={t("messages.searchPlaceholder", "Search messages in this chat")}
            aria-label={t("messages.searchChat", "Search in this chat")}
            className="min-w-0 flex-1 bg-transparent text-[14px] outline-none placeholder:text-muted-foreground"
          />
          {needle && <span className="shrink-0 text-xs text-muted-foreground">{shown.length}</span>}
          <button type="button" onClick={() => { setSearching(false); setSearchText(""); }} aria-label={t("common.close", "Close")} className={MSG.iconBtn}><X className="h-4 w-4" /></button>
        </div>
      )}

      {inRequests && convId && !viewAs && (
        <div data-testid="request-bar" className="shrink-0 border-b border-border bg-foreground/[0.03] px-4 py-3">
          <p className="text-[13px] font-semibold">{t("messages.request.title", "Message request")}</p>
          <p className="mt-0.5 text-[12px] leading-snug text-muted-foreground">{t("messages.request.note", "You don't follow this person. Accept to move this chat to your Chats.")}</p>
          <div className="mt-2.5 flex gap-2">
            <button type="button" onClick={() => accept.mutate(convId)} className={`${MSG.pill} flex-1 bg-primary text-primary-foreground hover:bg-primary/90`}>{t("messages.request.accept", "Accept")}</button>
            <button type="button" onClick={() => decline.mutate(convId, { onSuccess: () => navigate("/messages/requests", { replace: true }) })} className={`${MSG.pill} flex-1 bg-foreground/[0.08] text-foreground hover:bg-foreground/[0.12]`}>{t("messages.request.decline", "Decline")}</button>
          </div>
        </div>
      )}

      <div ref={scrollRef} onScroll={onThreadScroll} className={`${MSG.scroll} pb-2`} aria-live="polite">
        {!noMore && oldestFirst.length >= PAGE && (
          <button type="button" onClick={() => void loadOlder()} className="mx-auto mt-2 block text-[12px] font-medium text-muted-foreground hover:text-foreground" data-testid="load-older">
            {t("messages.loadOlder", "Load earlier messages")}
          </button>
        )}
        {thread.isLoading && convId && <p className="py-10 text-center text-sm text-muted-foreground">{t("common.loading", "Loading…")}</p>}
        {!thread.isLoading && items.length === 0 && (
          <div className="flex flex-col items-center px-8 py-16 text-center">
            <PersonAvatar person={person} size={64} />
            <p className="mt-2.5 flex items-center gap-1 text-[15px] font-semibold">{name}{otherId && <AutoBadge userId={otherId} only="verified" />}</p>
            <p className="mt-0.5 text-[13px] text-muted-foreground">{t("messages.thread.empty", "Say hello and start the conversation.")}</p>
          </div>
        )}
        {items.map((it) =>
          it.type === "day" ? (
            <DaySeparator key={it.key} label={it.label} />
          ) : (
            <MessageBubble
              key={it.key} m={it.m} mine={it.m.senderId === meId} first={it.first} last={it.last}
              onReply={allowed && !viewAs && !inRequests ? (msg) => { setReplyTo(msg); areaRef.current?.focus(); } : undefined}
              onJump={jumpTo} nameOf={quoteName}
              status={statusOf(it.m)}
              quotePhotoPath={it.m.reply?.photo ? photoById.get(it.m.reply.id) ?? null : null}
              onLongPress={viewAs ? undefined : setMenuFor}
            />
          ),
        )}
        {queued.map((q) => (
          <div key={q.id} data-testid="queued-message" className="mt-[2px] flex flex-col items-end px-3">
            <div className="max-w-[78%] whitespace-pre-wrap break-words rounded-[18px] bg-primary/60 px-3 py-[7px] text-[14px] leading-[1.4] text-primary-foreground sm:max-w-[65%]">{q.body}</div>
            <span className="mt-0.5 flex items-center gap-1 px-1 text-[11px] text-muted-foreground"><Clock aria-hidden className="h-3 w-3" />{t("messages.waitingNetwork", "Waiting for network")}</span>
          </div>
        ))}
        {live.typing && <TypingDots name={person?.fullName} />}
        {help && <HelplineCard onClose={() => setHelp(false)} />}
        <div ref={endRef} />
      </div>

      {viewAs ? (
        <p className={MSG.note} data-testid="view-as-note">
          Read-only view of {viewAs.name}'s chat. Nothing you do here is sent or marked as read.
        </p>
      ) : entry?.announcementOnly ? (
        <p className={MSG.note} data-testid="announcement-only-note">
          {t("messages.announcementOnly", "Only 50mm Retina World can write in this chat. You can read it here.")}
        </p>
      ) : !allowed ? (
        <p className={MSG.note} data-testid="send-off-note">
          {t("messages.sendOff", "Sending messages isn't available for your account. You can still read your chats.")}
        </p>
      ) : (
        <div className={MSG.composerWrap}>
          {error && <p role="alert" className="mb-1.5 px-2 text-xs font-medium text-destructive">{error}</p>}
          {replyTo && (
            <div data-testid="reply-bar" className="mb-1.5 flex items-center gap-2 rounded-xl border-l-[3px] border-primary bg-foreground/[0.06] px-2.5 py-1.5">
              <div className="min-w-0 flex-1 text-[13px]">
                <p className="flex min-w-0 items-center gap-1 text-[12px] font-semibold text-primary"><span className="truncate">{t("messages.replyingTo", "Replying to")} {quoteName(replyTo.senderId)}</span>{replyTo.senderId !== meId && <AutoBadge userId={replyTo.senderId} only="verified" />}</p>
                <p className="line-clamp-1 whitespace-pre-wrap break-words text-muted-foreground">{replyTo.body || (replyTo.photos.length > 0 ? t("messages.photo", "Photo") : "")}</p>
              </div>
              <button type="button" onClick={() => setReplyTo(null)} aria-label={t("messages.cancelReply", "Cancel reply")} className="grid h-7 w-7 shrink-0 place-items-center rounded-full text-muted-foreground hover:bg-foreground/10">
                <X className="h-4 w-4" />
              </button>
            </div>
          )}
          {chips.length > 0 && (
            <div data-testid="smart-replies" className="-mx-3 mb-1.5 flex gap-1.5 overflow-x-auto px-3 scrollbar-hide" aria-label={t("messages.suggested", "Suggested replies")}>
              {chips.map((c, i) => (
                <motion.button
                  key={c}
                  type="button"
                  initial={{ opacity: 0, y: 10, scale: 0.9 }}
                  animate={{ opacity: 1, y: 0, scale: 1 }}
                  transition={{ delay: 0.06 * i, type: "spring", stiffness: 380, damping: 22 }}
                  whileTap={{ scale: 0.94 }}
                  onClick={() => void sendText(c, false)}
                  disabled={busy}
                  className={`${MSG.pill} border border-border bg-background font-medium text-foreground hover:bg-muted`}
                >
                  {c}
                </motion.button>
              ))}
            </div>
          )}
          {picker && (
            <div data-testid="emoji-picker" className="absolute inset-x-3 bottom-full mb-2 rounded-2xl border border-border bg-background p-1.5 shadow-xl">
              <div role="tablist" className="mb-1 flex gap-1 px-1">
                {EMOJI_SETS.map((s, i) => (
                  <button key={s.id} type="button" role="tab" aria-selected={pickerTab === i} aria-label={s.label} onClick={() => setPickerTab(i)}
                    className={`grid h-9 flex-1 place-items-center rounded-xl text-lg ${pickerTab === i ? "bg-primary/15" : "hover:bg-foreground/5"}`}>{s.icon}</button>
                ))}
              </div>
              <div className="grid max-h-52 grid-cols-7 gap-0.5 overflow-y-auto scrollbar-hide sm:grid-cols-9">
                {EMOJI_SETS[pickerTab].items.map((e) => (
                  <motion.button key={e} type="button" aria-label={e} onClick={() => addEmoji(e)} whileHover={{ scale: 1.3, rotate: [0, -10, 10, 0] }} whileTap={{ scale: 0.85 }}
                    className="grid h-9 w-full place-items-center rounded-lg text-[22px] hover:bg-foreground/5">{e}</motion.button>
                ))}
              </div>
            </div>
          )}
          <div className={MSG.composerPill}>
            <input ref={fileRef} type="file" accept="image/jpeg,image/png,image/webp,image/heic" multiple hidden onChange={(e) => void onPickPhotos(e.target.files)} />
            <button type="button" onClick={() => setPicker((p) => !p)} aria-label={t("messages.emoji", "Emoji")} aria-expanded={picker} className={`${MSG.composerIcon} ${picker ? "text-primary" : ""}`}>
              <Smile className="h-5 w-5" />
            </button>
            <button type="button" onClick={() => fileRef.current?.click()} disabled={busy} aria-label={t("messages.addPhoto", "Add photo")} className={MSG.composerIcon}>
              {uploading ? <Loader2 className="h-5 w-5 animate-spin" /> : <ImagePlus className="h-5 w-5" />}
            </button>
            <textarea
              ref={areaRef}
              value={text}
              onChange={(e) => { setText(e.target.value.slice(0, 4000)); live.notifyTyping(e.target.value.trim().length > 0); }}
              rows={1}
              placeholder={t("messages.placeholder", "Message…")}
              aria-label={t("messages.placeholder", "Message…")}
              className={MSG.composerInput}
              onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void onSend(); } }}
            />
            {/* Send appears only once there is something to send (Instagram / WhatsApp) */}
            {(text.trim() || send.isPending) && (
              <button
                type="button"
                onClick={() => void onSend()}
                disabled={busy || !text.trim()}
                aria-label={t("messages.send", "Send")}
                className={MSG.sendBtn}
              >
                {send.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <SendHorizontal className="h-4 w-4" />}
              </button>
            )}
          </div>
        </div>
      )}

      {/* Hold a message (phone) / right-click (computer): its own small menu, from the bottom like WhatsApp */}
      {menuFor && (
        <div className="fixed inset-0 z-[70] flex items-end bg-black/40" onClick={() => setMenuFor(null)} data-testid="message-menu">
          <div className="w-full rounded-t-2xl border-t border-border bg-background pb-[max(8px,var(--safe-bottom))] pt-1.5" onClick={(e) => e.stopPropagation()}>
            <p className="line-clamp-2 px-4 pb-1.5 pt-1 text-[12px] text-muted-foreground">{menuFor.body || t("messages.photo", "Photo")}</p>
            {allowed && !inRequests && (
              <button type="button" className="flex h-12 w-full items-center gap-3 px-4 text-left text-[15px] hover:bg-foreground/5" onClick={() => { setReplyTo(menuFor); setMenuFor(null); areaRef.current?.focus(); }}>
                <Reply className="h-5 w-5" />{t("messages.reply", "Reply")}
              </button>
            )}
            {menuFor.body && (
              <button type="button" className="flex h-12 w-full items-center gap-3 px-4 text-left text-[15px] hover:bg-foreground/5" onClick={() => { void navigator.clipboard?.writeText(menuFor.body).catch(() => undefined); setMenuFor(null); }}>
                <Copy className="h-5 w-5" />{t("messages.copy", "Copy")}
              </button>
            )}
            <button type="button" className="flex h-12 w-full items-center gap-3 px-4 text-left text-[15px] text-muted-foreground hover:bg-foreground/5" onClick={() => setMenuFor(null)}>
              <X className="h-5 w-5" />{t("common.cancel", "Cancel")}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

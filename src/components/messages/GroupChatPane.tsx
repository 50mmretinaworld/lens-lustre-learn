/**
 * Messages · one GROUP chat (a chat with a name and 3 to 20 members). Text only, like the server door (message_send_group).
 * Each run of someone else's messages carries their name; the header shows the name and member count, and a menu opens the
 * member list (the owner can add friends and remove members) or leaves the group.
 * The 1:1 chat keeps its own screen (ChatPane); MessagesRoutes picks this one when the chat's kind is "group".
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useMutation } from "@tanstack/react-query";
import { Loader2, LogOut, MoreVertical, SendHorizontal, UserPlus, Users, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { toast } from "@/hooks/core/use-toast";
import { useT } from "@/i18n/I18nContext";
import { useAuth } from "@/hooks/core/useAuth";
import { newClientMsgId, useConversationActions, useConversations, useThread } from "@/hooks/messages/useMessages";
import { useGroupFriends, useGroupMembers, useRefreshGroupMembers } from "@/hooks/messages/useGroups";
import { useChatLive } from "@/hooks/messages/useChatLive";
import { groupAddMember, groupLeave, groupRemoveMember, sendGroupMessage } from "@/lib/messages/groups";
import { MessageSendError } from "@/lib/messages/api";
import { groupChat } from "@/lib/messages/format";
import { HelplineCard, MessageBubble, PersonAvatar, refusalText } from "@/components/messages/MessageParts";
import { ChatHeader, DaySeparator, HeaderTitle, MSG } from "@/components/messages/ui";
import AutoBadge from "@/components/AutoBadge";

function MembersDialog({ conversationId, open, onOpenChange, meId }: { conversationId: string; open: boolean; onOpenChange: (o: boolean) => void; meId: string | undefined }) {
  const t = useT();
  const members = useGroupMembers(open ? conversationId : null);
  const refresh = useRefreshGroupMembers();
  const [adding, setAdding] = useState(false);
  const friends = useGroupFriends(open && adding);
  const list = members.data ?? [];
  const iAmOwner = list.some((m) => m.userId === meId && m.role === "owner");
  const addable = (friends.data ?? []).filter((f) => !list.some((m) => m.userId === f.userId));
  const change = useMutation({
    mutationFn: async (a: { kind: "add" | "remove"; userId: string }) => (a.kind === "add" ? groupAddMember(conversationId, a.userId) : groupRemoveMember(conversationId, a.userId)),
    onSuccess: () => { void refresh(conversationId); },
    onError: (e) => toast({ title: t("messages.group.failed", "Could not change the group"), description: refusalText(e instanceof MessageSendError ? e.refusal : "unknown"), variant: "destructive" }),
  });
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md" data-testid="group-members-dialog">
        <DialogHeader>
          <DialogTitle>{t("messages.group.members", "Members")} · {list.length}</DialogTitle>
          <DialogDescription>{iAmOwner ? t("messages.group.ownerHint", "You made this group. You can add friends and remove members.") : t("messages.group.memberHint", "The people in this group.")}</DialogDescription>
        </DialogHeader>
        <ul className="max-h-72 space-y-0.5 overflow-y-auto">
          {list.map((m) => (
            <li key={m.userId} className="flex items-center gap-3 rounded-xl px-2 py-1.5">
              <PersonAvatar person={m} size={36} />
              <span className="flex min-w-0 flex-1 items-center gap-1 text-sm font-medium"><span className="truncate">{m.userId === meId ? t("messages.you", "You") : (m.fullName || m.username || "Member")}</span><AutoBadge userId={m.userId} only="verified" /></span>
              {m.role === "owner" && <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] text-muted-foreground">{t("messages.group.owner", "Owner")}</span>}
              {iAmOwner && m.role !== "owner" && (
                <button type="button" aria-label={t("messages.group.remove", "Remove from group")} onClick={() => change.mutate({ kind: "remove", userId: m.userId })} className="grid h-8 w-8 place-items-center rounded-full text-muted-foreground hover:bg-destructive/10 hover:text-destructive"><X className="h-4 w-4" /></button>
              )}
            </li>
          ))}
        </ul>
        {iAmOwner && list.length < 20 && (
          <div className="border-t border-border pt-2">
            {!adding
              ? <Button variant="outline" size="sm" onClick={() => setAdding(true)} data-testid="group-add-open"><UserPlus className="mr-1 h-4 w-4" aria-hidden="true" />{t("messages.group.add", "Add a friend")}</Button>
              : (
                <ul className="max-h-40 space-y-0.5 overflow-y-auto">
                  {friends.isLoading && <li className="py-2 text-center text-sm text-muted-foreground">{t("common.loading", "Loading…")}</li>}
                  {!friends.isLoading && addable.length === 0 && <li className="py-2 text-center text-sm text-muted-foreground">{t("messages.group.noneToAdd", "No other friends with chat to add.")}</li>}
                  {addable.map((f) => (
                    <li key={f.userId} className="flex items-center gap-3 rounded-xl px-2 py-1.5">
                      <PersonAvatar person={f} size={32} />
                      <span className="min-w-0 flex-1 truncate text-sm">{f.fullName || f.username || "Member"}</span>
                      <Button size="sm" variant="outline" disabled={change.isPending} onClick={() => change.mutate({ kind: "add", userId: f.userId })}>{t("messages.group.addShort", "Add")}</Button>
                    </li>
                  ))}
                </ul>
              )}
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

export default function GroupChatPane({ conversationId, onBack }: { conversationId: string; onBack: () => void }) {
  const t = useT();
  const navigate = useNavigate();
  const { user } = useAuth();
  const meId = user?.id;
  const inbox = useConversations("inbox");
  const entry = (inbox.data ?? []).find((c) => c.conversationId === conversationId);
  const members = useGroupMembers(conversationId);
  const nameById = useMemo(() => new Map((members.data ?? []).map((m) => [m.userId, m.fullName || m.username || "Member"])), [members.data]);
  const nameOf = (id: string) => (id === meId ? t("messages.you", "You") : (nameById.get(id) ?? "Member"));
  const thread = useThread(conversationId);
  const oldestFirst = useMemo(() => [...(thread.data ?? [])].reverse(), [thread.data]);
  const items = useMemo(() => groupChat(oldestFirst), [oldestFirst]);
  const live = useChatLive(conversationId, meId, true);
  const { markRead } = useConversationActions();
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [help, setHelp] = useState(false);
  const [showMembers, setShowMembers] = useState(false);
  const attempt = useRef<{ body: string; id: string } | null>(null);
  const endRef = useRef<HTMLDivElement>(null);
  const lastMarked = useRef<number | null>(null);
  const newestId = oldestFirst.length ? oldestFirst[oldestFirst.length - 1].id : null;

  useEffect(() => { endRef.current?.scrollIntoView({ block: "end" }); }, [newestId, help]);
  useEffect(() => {
    if (newestId !== null && lastMarked.current !== newestId) {
      lastMarked.current = newestId;
      markRead.mutate(conversationId, { onSuccess: () => live.ping() });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- markRead is a stable mutation object per render; the guard above is the dedupe
  }, [conversationId, newestId]);

  const send = useMutation({ mutationFn: (a: { body: string; id: string }) => sendGroupMessage(conversationId, a.body, a.id) });
  const sendNow = async () => {
    const body = text.trim();
    if (!body || send.isPending) return;
    setError(null);
    const id = attempt.current?.body === body ? attempt.current.id : newClientMsgId();
    attempt.current = { body, id };
    try {
      const r = await send.mutateAsync({ body, id });
      attempt.current = null;
      setText("");
      live.ping();
      if (r.help) setHelp(true);
      void thread.refetch();
    } catch (e) {
      setError(refusalText(e instanceof MessageSendError ? e.refusal : "unknown"));
    }
  };

  const leave = useMutation({
    mutationFn: () => groupLeave(conversationId),
    onSuccess: () => { toast({ title: t("messages.group.left", "You left the group") }); navigate("/messages", { replace: true }); },
    onError: (e) => toast({ title: t("messages.group.failed", "Could not leave the group"), description: refusalText(e instanceof MessageSendError ? e.refusal : "unknown"), variant: "destructive" }),
  });

  const title = entry?.title || t("messages.group.untitled", "Group");
  const count = members.data?.length;

  return (
    <div className="flex h-full min-h-0 flex-col bg-background" data-testid="group-chat">
      <ChatHeader
        onBack={onBack}
        actions={(
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button type="button" aria-label={t("messages.menu", "More options")} data-testid="group-menu" className={MSG.iconBtn}><MoreVertical className="h-5 w-5" /></button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="min-w-[200px]">
              <DropdownMenuItem className={MSG.menuItem} onSelect={() => setShowMembers(true)}><Users className="h-4 w-4" />{t("messages.group.members", "Members")}</DropdownMenuItem>
              <DropdownMenuItem
                className={`${MSG.menuItem} text-destructive focus:text-destructive`} data-testid="group-leave"
                onSelect={() => { if (window.confirm(t("messages.group.leaveConfirm", "Leave this group? You will stop receiving its messages."))) leave.mutate(); }}
              ><LogOut className="h-4 w-4" />{t("messages.group.leave", "Leave group")}</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      >
        <button type="button" onClick={() => setShowMembers(true)} className="flex min-w-0 flex-1 items-center gap-2.5 text-left hover:opacity-90" data-testid="group-header">
          <span className="grid h-[34px] w-[34px] shrink-0 place-items-center rounded-full bg-foreground/[0.07] text-muted-foreground"><Users className="h-4 w-4" aria-hidden="true" /></span>
          <HeaderTitle title={title} sub={count ? t("messages.group.count", "{n} members").replace("{n}", String(count)) : t("messages.group.members", "Members")} />
        </button>
      </ChatHeader>

      <div className={`${MSG.scroll} pb-2`} aria-live="polite">
        {thread.isLoading && <p className="py-10 text-center text-[13px] text-muted-foreground">{t("common.loading", "Loading…")}</p>}
        {!thread.isLoading && items.length === 0 && <p className="px-8 py-16 text-center text-[13px] text-muted-foreground">{t("messages.thread.empty", "Say hello and start the conversation.")}</p>}
        {items.map((it) =>
          it.type === "day" ? (
            <DaySeparator key={it.key} label={it.label} />
          ) : (
            <div key={it.key}>
              {it.first && it.m.senderId !== meId && (
                <p className="flex items-center gap-1 px-4 pt-2 text-[11px] font-semibold text-muted-foreground" data-testid="group-sender">{nameOf(it.m.senderId)}<AutoBadge userId={it.m.senderId} only="verified" /></p>
              )}
              <MessageBubble m={it.m} mine={it.m.senderId === meId} first={it.first} last={it.last} nameOf={nameOf} />
            </div>
          ),
        )}
        {help && <HelplineCard onClose={() => setHelp(false)} />}
        <div ref={endRef} />
      </div>

      <div className={MSG.composerWrap}>
        {error && <p role="alert" className="mb-1.5 px-2 text-xs font-medium text-destructive" data-testid="group-error">{error}</p>}
        <div className={MSG.composerPill}>
          <textarea
            value={text} onChange={(e) => { setText(e.target.value); live.notifyTyping(e.target.value.trim().length > 0); }} rows={1} maxLength={4000}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); void sendNow(); } }}
            placeholder={t("messages.placeholder", "Message…")} aria-label={t("messages.placeholder", "Message…")} data-testid="group-input"
            className={`${MSG.composerInput} pl-2.5`}
          />
          <button type="button" onClick={() => void sendNow()} disabled={!text.trim() || send.isPending} aria-label={t("messages.send", "Send")} data-testid="group-send"
            className={MSG.sendBtn}>
            {send.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <SendHorizontal className="h-4 w-4" />}
          </button>
        </div>
      </div>
      <MembersDialog conversationId={conversationId} open={showMembers} onOpenChange={setShowMembers} meId={meId} />
    </div>
  );
}

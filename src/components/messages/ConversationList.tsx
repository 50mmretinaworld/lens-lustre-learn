/**
 * Messages · the chat list: ← Messages, search, Chats | Requests, and the rows. Compact, the app's own pattern
 * (Owner 22 Nov 2026) — sizes and the header come from ./ui (one look for every messenger screen).
 * Reading is always allowed (even when sending is off or the account is under review).
 */
import { lazy, Suspense, useMemo, useState } from "react";
import { Camera, MessageCircle, Search, SquarePen, Users } from "lucide-react";
import { useT } from "@/i18n/I18nContext";
import { useAuth } from "@/hooks/core/useAuth";
import { relativeAge } from "@/lib/notifications/describe";
import { useConversations, useUnreadCounts } from "@/hooks/messages/useMessages";
import AutoBadge from "@/components/AutoBadge";
import { PersonAvatar, Ticks } from "@/components/messages/MessageParts";
import { MSG, PageBar } from "@/components/messages/ui";
import { useViewAs } from "@/components/messages/viewAs";
import { useGroupsAllowed } from "@/hooks/messages/useGroups";

const NewGroupDialog = lazy(() => import("@/components/messages/NewGroupDialog"));
import type { ConversationSummary, MessageFolder } from "@/lib/messages/api";

const AVATAR = 48;

function Row({ c, active, meId, onOpen }: { c: ConversationSummary; active: boolean; meId: string | undefined; onOpen: () => void }) {
  const mine = c.last?.senderId === meId;
  const name = c.kind === "group" ? c.title || "Group" : c.other?.fullName || "Member";
  const photo = c.last?.kind === "photo" && !c.last.body;
  const unread = c.unread > 0;
  return (
    <li>
      <button
        type="button"
        data-testid="conversation-row"
        aria-current={active ? "true" : undefined}
        onClick={onOpen}
        className={`flex w-full items-center gap-3 px-4 py-2 text-left transition-colors ${active ? "bg-foreground/[0.06]" : "hover:bg-foreground/[0.03]"}`}
      >
        {c.kind === "group"
          ? <span aria-hidden className="grid shrink-0 place-items-center rounded-full bg-foreground/[0.07] text-muted-foreground" style={{ width: AVATAR, height: AVATAR }}><Users className="h-5 w-5" /></span>
          : <PersonAvatar person={c.other} size={AVATAR} showOnline />}
        <span className="min-w-0 flex-1">
          <span className="flex items-center gap-1">
            <span className={`truncate text-[14px] leading-5 ${unread ? "font-bold text-foreground" : "font-semibold text-foreground"}`}>{name}</span>
            {c.kind === "direct" && <AutoBadge userId={c.other?.userId} only="verified" />}
          </span>
          <span className={`flex min-w-0 items-center gap-1 text-[13px] leading-[18px] ${unread ? "font-semibold text-foreground" : "text-muted-foreground"}`}>
            {mine && <Ticks tick={c.last?.tick} />}
            {mine && <span className="shrink-0">You:</span>}
            {photo && <Camera className="h-3.5 w-3.5 shrink-0" />}
            <span className="truncate">{photo ? "Photo" : c.last?.body}</span>
            {c.lastMessageAt && <span className="shrink-0 font-normal text-muted-foreground">· {relativeAge(c.lastMessageAt)}</span>}
          </span>
        </span>
        {unread && (
          <span aria-label={`${c.unread} unread`} data-testid="unread-dot" className="h-2 w-2 shrink-0 rounded-full bg-primary" />
        )}
      </button>
    </li>
  );
}

export default function ConversationList({ activeId, onOpen, folder: folderProp, onFolder, onBack }: {
  activeId: string | null;
  onOpen: (conversationId: string) => void;
  /** the messenger page keeps the folder in the address (/messages · /messages/requests); the admin viewer does not */
  folder?: MessageFolder;
  onFolder?: (folder: MessageFolder) => void;
  /** the messenger page's back arrow (leaves Messages); the admin viewer has none */
  onBack?: () => void;
}) {
  const t = useT();
  const { user } = useAuth();
  const viewAs = useViewAs();   // admin viewing a member's box: that member is "me", no unread badges of the admin
  const [ownFolder, setOwnFolder] = useState<MessageFolder>("inbox");
  const folder = folderProp ?? ownFolder;
  const setFolder = (f: MessageFolder) => (onFolder ? onFolder(f) : setOwnFolder(f));
  const [q, setQ] = useState("");
  const groupsAllowed = useGroupsAllowed();
  const [newGroup, setNewGroup] = useState(false);
  const ownUnread = useUnreadCounts();
  const unread = viewAs ? { inbox: 0, requests: 0 } : ownUnread;
  const { data, isLoading, isError } = useConversations(folder);
  const rows = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const all = data ?? [];
    return needle ? all.filter((c) => (c.other?.fullName ?? c.title ?? "").toLowerCase().includes(needle) || (c.last?.body ?? "").toLowerCase().includes(needle)) : all;
  }, [data, q]);

  // Instagram-style text tabs with an underline (no big pills)
  const tab = (f: MessageFolder, label: string, badge: number) => (
    <button
      type="button"
      role="tab"
      aria-selected={folder === f}
      onClick={() => setFolder(f)}
      className={`relative flex h-10 flex-1 items-center justify-center gap-1.5 text-[13px] font-semibold transition-colors ${folder === f ? "text-foreground" : "text-muted-foreground hover:text-foreground"}`}
    >
      {label}
      {badge > 0 && <span className="grid h-4 min-w-4 place-items-center rounded-full bg-primary px-1 text-[10px] font-bold leading-none text-primary-foreground">{badge > 99 ? "99+" : badge}</span>}
      {folder === f && <span aria-hidden className="absolute inset-x-6 bottom-0 h-0.5 rounded-full bg-foreground" />}
    </button>
  );

  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageBar
        title={t("messages.title", "Messages")}
        onBack={onBack}
        actions={groupsAllowed && !viewAs ? (
          <button type="button" onClick={() => setNewGroup(true)} data-testid="new-group-open" aria-label={t("messages.group.new", "New group")} title={t("messages.group.new", "New group")} className={MSG.iconBtn}>
            <SquarePen className="h-5 w-5" aria-hidden="true" />
          </button>
        ) : undefined}
      />
      <div className="shrink-0 px-4 pt-2.5">
        <label className="flex h-9 items-center gap-2 rounded-xl bg-foreground/[0.06] px-3 text-muted-foreground focus-within:ring-1 focus-within:ring-primary/60">
          <Search className="h-4 w-4 shrink-0" />
          <input
            type="search"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder={t("messages.search", "Search chats")}
            aria-label={t("messages.search", "Search chats")}
            className="w-full min-w-0 bg-transparent text-[14px] text-foreground placeholder:text-muted-foreground focus:outline-none"
          />
        </label>
      </div>
      <div role="tablist" className="mt-1 flex shrink-0 border-b border-border px-2">
        {tab("inbox", t("messages.tab.messages", "Chats"), unread.inbox)}
        {tab("requests", t("messages.tab.requests", "Requests"), unread.requests)}
      </div>

      <div className={`${MSG.scroll} py-1`}>
        {isLoading && <p className="px-4 py-10 text-center text-[13px] text-muted-foreground">{t("common.loading", "Loading…")}</p>}
        {isError && <p className="px-4 py-10 text-center text-[13px] text-muted-foreground">{t("messages.error", "Couldn't load your messages. Try again in a moment.")}</p>}
        {!isLoading && !isError && rows.length === 0 && (
          <div className="px-8 py-14 text-center">
            <MessageCircle className="mx-auto mb-2.5 h-9 w-9 text-muted-foreground/70" strokeWidth={1.5} />
            <p className="mx-auto max-w-[26ch] text-[13px] text-muted-foreground">
              {q.trim()
                ? t("messages.empty.search", "No chats match your search.")
                : folder === "inbox"
                  ? t("messages.empty.inbox", "No messages yet. Open a profile you follow and tap the message icon.")
                  : t("messages.empty.requests", "No requests. Messages from people you don't follow land here first.")}
            </p>
          </div>
        )}
        <ul>
          {rows.map((c) => <Row key={c.conversationId} c={c} active={c.conversationId === activeId} meId={viewAs?.userId ?? user?.id} onOpen={() => onOpen(c.conversationId)} />)}
        </ul>
      </div>
      {newGroup && <Suspense fallback={null}><NewGroupDialog open={newGroup} onOpenChange={setNewGroup} onCreated={onOpen} /></Suspense>}
    </div>
  );
}

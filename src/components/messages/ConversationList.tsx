/**
 * Messages · the conversation pane: title, search, Chats | Requests, and the rows.
 * Reading is always allowed (even when sending is off or the account is under review).
 */
import { useMemo, useState } from "react";
import { Camera, MessageCircle, Search } from "lucide-react";
import { useT } from "@/i18n/I18nContext";
import { useAuth } from "@/hooks/core/useAuth";
import { relativeAge } from "@/lib/notifications/describe";
import { useConversations, useUnreadCounts } from "@/hooks/messages/useMessages";
import { PersonAvatar, headingFont } from "@/components/messages/MessageParts";
import { useViewAs } from "@/components/messages/viewAs";
import type { ConversationSummary, MessageFolder } from "@/lib/messages/api";

function Row({ c, active, meId, onOpen }: { c: ConversationSummary; active: boolean; meId: string | undefined; onOpen: () => void }) {
  const mine = c.last?.senderId === meId;
  const name = c.kind === "group" ? c.title || "Group" : c.other?.fullName || "Member";
  const photo = c.last?.kind === "photo" && !c.last.body;
  return (
    <li>
      <button
        type="button"
        data-testid="conversation-row"
        aria-current={active ? "true" : undefined}
        onClick={onOpen}
        className={`flex w-full items-center gap-3.5 rounded-2xl px-3 py-2.5 text-left transition-colors ${active ? "bg-primary/10" : "hover:bg-muted/60"}`}
      >
        <PersonAvatar person={c.other} size={54} />
        <span className="min-w-0 flex-1">
          <span className="flex items-baseline justify-between gap-2">
            <span className={`truncate text-[15px] ${c.unread > 0 ? "font-bold" : "font-semibold"}`} style={headingFont}>{name}</span>
            {c.lastMessageAt && <span className={`shrink-0 text-xs ${c.unread > 0 ? "font-semibold text-primary" : "text-muted-foreground"}`}>{relativeAge(c.lastMessageAt)}</span>}
          </span>
          <span className="mt-0.5 flex items-center gap-2">
            <span className={`flex min-w-0 flex-1 items-center gap-1 truncate text-sm ${c.unread > 0 ? "font-medium text-foreground" : "text-muted-foreground"}`}>
              {mine && <span className="shrink-0">You:</span>}
              {photo && <Camera className="h-3.5 w-3.5 shrink-0" />}
              <span className="truncate">{photo ? "Photo" : c.last?.body}</span>
            </span>
            {c.unread > 0 && (
              <span aria-label={`${c.unread} unread`} className="grid h-5 min-w-5 shrink-0 place-items-center rounded-full bg-gradient-to-br from-primary to-amber-400 px-1.5 text-[11px] font-bold leading-none text-white">
                {c.unread > 99 ? "99+" : c.unread}
              </span>
            )}
          </span>
        </span>
      </button>
    </li>
  );
}

export default function ConversationList({ activeId, onOpen }: { activeId: string | null; onOpen: (conversationId: string) => void }) {
  const t = useT();
  const { user } = useAuth();
  const viewAs = useViewAs();   // admin viewing a member's box: that member is "me", no unread badges of the admin
  const [folder, setFolder] = useState<MessageFolder>("inbox");
  const [q, setQ] = useState("");
  const ownUnread = useUnreadCounts();
  const unread = viewAs ? { inbox: 0, requests: 0 } : ownUnread;
  const { data, isLoading, isError } = useConversations(folder);
  const rows = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const all = data ?? [];
    return needle ? all.filter((c) => (c.other?.fullName ?? c.title ?? "").toLowerCase().includes(needle) || (c.last?.body ?? "").toLowerCase().includes(needle)) : all;
  }, [data, q]);

  const seg = (f: MessageFolder, label: string, badge: number) => (
    <button
      type="button"
      role="tab"
      aria-selected={folder === f}
      onClick={() => setFolder(f)}
      className={`flex flex-1 items-center justify-center gap-1.5 rounded-full py-2.5 text-sm font-semibold transition-colors ${folder === f ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"}`}
      style={headingFont}
    >
      {label}
      {badge > 0 && <span className="grid h-[18px] min-w-[18px] place-items-center rounded-full bg-primary px-1 text-[10px] font-bold leading-none text-primary-foreground">{badge > 99 ? "99+" : badge}</span>}
    </button>
  );

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="px-4 pb-3 pt-4">
        <h1 className="text-[26px] font-bold leading-tight tracking-tight" style={headingFont}>{t("messages.title", "Messages")}</h1>
        <label className="mt-3 flex items-center gap-2 rounded-full bg-foreground/[0.07] px-3.5 py-3 text-muted-foreground focus-within:ring-2 focus-within:ring-primary">
          <Search className="h-4 w-4 shrink-0" />
          <input
            type="search"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder={t("messages.search", "Search chats")}
            aria-label={t("messages.search", "Search chats")}
            className="w-full min-w-0 bg-transparent text-[15px] text-foreground placeholder:text-muted-foreground focus:outline-none"
          />
        </label>
        <div role="tablist" className="mt-3 flex gap-1 rounded-full bg-foreground/[0.07] p-1">
          {seg("inbox", t("messages.tab.messages", "Chats"), unread.inbox)}
          {seg("requests", t("messages.tab.requests", "Requests"), unread.requests)}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-2 pb-4">
        {isLoading && <p className="px-4 py-10 text-center text-sm text-muted-foreground">{t("common.loading", "Loading…")}</p>}
        {isError && <p className="px-4 py-10 text-center text-sm text-muted-foreground">{t("messages.error", "Couldn't load your messages. Try again in a moment.")}</p>}
        {!isLoading && !isError && rows.length === 0 && (
          <div className="px-6 py-14 text-center">
            <span className="mx-auto mb-3 grid h-16 w-16 place-items-center rounded-full bg-gradient-to-br from-primary/15 to-amber-400/15 text-primary"><MessageCircle className="h-7 w-7" /></span>
            <p className="mx-auto max-w-[24ch] text-sm text-muted-foreground">
              {q.trim()
                ? t("messages.empty.search", "No chats match your search.")
                : folder === "inbox"
                  ? t("messages.empty.inbox", "No messages yet. Open a profile you follow and tap the message icon.")
                  : t("messages.empty.requests", "No requests. Messages from people you don't follow land here first.")}
            </p>
          </div>
        )}
        <ul className="space-y-0.5">
          {rows.map((c) => <Row key={c.conversationId} c={c} active={c.conversationId === activeId} meId={viewAs?.userId ?? user?.id} onOpen={() => onOpen(c.conversationId)} />)}
        </ul>
      </div>
    </div>
  );
}

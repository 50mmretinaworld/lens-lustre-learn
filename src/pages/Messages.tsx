/**
 * /messages — the inbox: Messages and Requests (people you follow who do not follow back).
 * Reading is always allowed (even when sending is off or the account is under review);
 * the server decides who can send. Plain text only.
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, MessageCircle } from "lucide-react";
import { useT } from "@/i18n/I18nContext";
import { goBackOrFeed } from "@/lib/navigationContract";
import { inAppHistoryDepth } from "@/hooks/core/useAndroidBackButton";
import { relativeAge } from "@/lib/notifications/describe";
import { useAuth } from "@/hooks/core/useAuth";
import { useConversations, useUnreadCounts } from "@/hooks/messages/useMessages";
import { PersonAvatar, headingFont } from "@/components/messages/MessageParts";
import type { MessageFolder } from "@/lib/messages/api";

export default function Messages() {
  const t = useT();
  const navigate = useNavigate();
  const { user, loading: authLoading } = useAuth();
  useEffect(() => { if (!authLoading && !user) navigate("/login", { replace: true }); }, [authLoading, user, navigate]);
  const [folder, setFolder] = useState<MessageFolder>("inbox");
  const unread = useUnreadCounts();
  const { data, isLoading, isError } = useConversations(folder);
  const rows = data ?? [];

  const tab = (f: MessageFolder, label: string, badge: number) => (
    <button
      type="button"
      role="tab"
      aria-selected={folder === f}
      onClick={() => setFolder(f)}
      className={`relative flex-1 py-3 text-sm font-semibold transition-colors ${folder === f ? "text-foreground" : "text-muted-foreground"}`}
      style={headingFont}
    >
      {label}
      {badge > 0 && <span className="ml-1.5 rounded-full bg-primary px-1.5 py-0.5 text-[10px] font-bold text-primary-foreground">{badge > 99 ? "99+" : badge}</span>}
      {folder === f && <span className="absolute inset-x-6 bottom-0 h-0.5 rounded bg-primary" />}
    </button>
  );

  return (
    <div className="mx-auto max-w-2xl pb-16">
      <div className="flex items-center gap-3 border-b border-border px-4 py-4">
        <button type="button" onClick={() => goBackOrFeed(navigate, inAppHistoryDepth())} aria-label={t("common.back", "Back")} className="p-1 -ml-1 tap-44 text-foreground hover:text-primary transition-colors">
          <ArrowLeft className="h-5 w-5" />
        </button>
        <h1 className="text-base uppercase tracking-[0.08em] text-foreground" style={headingFont}>{t("messages.title", "Messages")}</h1>
      </div>
      <div role="tablist" className="flex border-b border-border">
        {tab("inbox", t("messages.tab.messages", "Messages"), unread.inbox)}
        {tab("requests", t("messages.tab.requests", "Requests"), unread.requests)}
      </div>

      {isLoading && <p className="px-4 py-10 text-center text-sm text-muted-foreground">{t("common.loading", "Loading…")}</p>}
      {isError && <p className="px-4 py-10 text-center text-sm text-muted-foreground">{t("messages.error", "Couldn't load your messages. Pull to try again.")}</p>}
      {!isLoading && !isError && rows.length === 0 && (
        <div className="px-6 py-16 text-center">
          <MessageCircle className="mx-auto mb-3 h-10 w-10 text-muted-foreground/30" />
          <p className="text-sm text-muted-foreground">
            {folder === "inbox"
              ? t("messages.empty.inbox", "No messages yet. Open a profile you follow and tap Message.")
              : t("messages.empty.requests", "No requests. Messages from people you follow who don't follow you back land here.")}
          </p>
        </div>
      )}

      <ul>
        {rows.map((c) => {
          const mine = c.last?.senderId === user?.id;
          const name = c.kind === "group" ? c.title || "Group" : c.other?.fullName || "Member";
          return (
            <li key={c.conversationId}>
              <button
                type="button"
                data-testid="conversation-row"
                onClick={() => navigate(`/messages/${c.conversationId}`)}
                className="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-muted/50"
              >
                <PersonAvatar person={c.other} size={48} />
                <span className="min-w-0 flex-1">
                  <span className="flex items-baseline justify-between gap-2">
                    <span className={`truncate text-[15px] ${c.unread > 0 ? "font-bold" : "font-semibold"}`} style={headingFont}>{name}</span>
                    {c.lastMessageAt && <span className="shrink-0 text-xs text-muted-foreground">{relativeAge(c.lastMessageAt)}</span>}
                  </span>
                  <span className={`block truncate text-sm ${c.unread > 0 ? "text-foreground" : "text-muted-foreground"}`}>
                    {c.last ? `${mine ? "You: " : ""}${c.last.kind === "photo" && !c.last.body ? "Photo" : c.last.body}` : ""}
                  </span>
                </span>
                {c.unread > 0 && <span aria-label={`${c.unread} unread`} className="h-2.5 w-2.5 shrink-0 rounded-full bg-primary" />}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

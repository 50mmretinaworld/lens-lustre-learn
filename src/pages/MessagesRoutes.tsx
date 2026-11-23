/**
 * /messages/* — the messenger. Addresses (same shape as Instagram / Messenger):
 *   /messages                 the chat list (Chats)
 *   /messages/requests        the chat list, Requests folder
 *   /messages/<chat id>       one chat — group or one-to-one, the chat itself decides which screen (useChatKind)
 *   /messages/with/<member>   start / open the chat with a member; becomes /messages/<chat id> once the chat exists
 * Wide screens show the list and the chat side by side; a phone shows one at a time. No site footer here (Layout
 * leaves it out): the messenger fills the screen. Back from a chat returns to the folder it was opened from.
 */
import { Loader2, MessageCircle } from "lucide-react";
import { matchPath, useLocation, useNavigate } from "react-router-dom";
import { useT } from "@/i18n/I18nContext";
import { useAuth } from "@/hooks/core/useAuth";
import { useEffect } from "react";
import ConversationList from "@/components/messages/ConversationList";
import ChatPane from "@/components/messages/ChatPane";
import GroupChatPane from "@/components/messages/GroupChatPane";
import { useChatKind } from "@/hooks/messages/useChatKind";
import { goBackOrFeed } from "@/lib/navigationContract";
import { inAppHistoryDepth } from "@/hooks/core/useAndroidBackButton";
import type { MessageFolder } from "@/lib/messages/api";

const FOLDER_SEGMENTS: Record<string, MessageFolder> = { requests: "requests" };
const folderPath = (f: MessageFolder) => (f === "inbox" ? "/messages" : `/messages/${f}`);

export default function MessagesRoutes() {
  const t = useT();
  const navigate = useNavigate();
  const location = useLocation();
  const { pathname } = location;
  const { user, loading } = useAuth();
  useEffect(() => { if (!loading && !user) navigate("/login", { replace: true }); }, [loading, user, navigate]);

  const withUser = matchPath("/messages/with/:userId", pathname)?.params.userId ?? null;
  const segment = withUser ? null : (matchPath("/messages/:segment", pathname)?.params.segment ?? null);
  const folderFromPath = segment ? FOLDER_SEGMENTS[segment] ?? null : null;
  const chatId = folderFromPath ? null : segment;
  // a chat remembers the folder it was opened from (Back goes there); a push or a link opens from Chats
  const openedFrom = (location.state as { folder?: MessageFolder } | null)?.folder;
  const folder: MessageFolder = folderFromPath ?? (openedFrom === "requests" ? "requests" : "inbox");
  const hasChat = !!(withUser || chatId);
  const kind = useChatKind(chatId);
  const back = () => navigate(folderPath(folder));

  return (
    // a chat fills the phone screen (no app bar, no tab bar — lib/appBar); the list sits between the two bars
    <div className={`mx-auto ${hasChat ? "h-app" : "h-[calc(100dvh_-_7.5rem_-_var(--banner-h))]"} w-full max-w-[1100px] lg:h-[calc(100dvh_-_6.5rem_-_var(--banner-h))] lg:px-4 lg:py-3`}>
      <div className="flex h-full overflow-hidden bg-background lg:rounded-2xl lg:border lg:border-border">
        <section aria-label={t("messages.title", "Messages")} className={`${hasChat ? "hidden lg:block" : "block"} h-full w-full shrink-0 lg:w-[340px] lg:border-r lg:border-border`}>
          <ConversationList
            activeId={chatId}
            folder={folder}
            onFolder={(f) => navigate(folderPath(f))}
            onOpen={(id) => navigate(`/messages/${id}`, { state: { folder } })}
            onBack={() => goBackOrFeed(navigate, inAppHistoryDepth())}
          />
        </section>
        <section className={`${hasChat ? "block" : "hidden lg:block"} h-full min-w-0 flex-1`}>
          {withUser ? (
            <ChatPane key={withUser} conversationId={null} userId={withUser} onBack={back} />
          ) : chatId ? (
            kind === "group" ? <GroupChatPane key={chatId} conversationId={chatId} onBack={back} />
              : kind === "direct" ? <ChatPane key={chatId} conversationId={chatId} userId={null} onBack={back} />
              : <div className="grid h-full place-items-center" data-testid="chat-kind-loading"><Loader2 className="h-6 w-6 animate-spin text-muted-foreground" aria-label={t("common.loading", "Loading")} /></div>
          ) : (
            <div className="grid h-full place-items-center px-8 text-center">
              <div>
                <MessageCircle className="mx-auto mb-3 h-12 w-12 text-muted-foreground/70" strokeWidth={1.25} />
                <h2 className="text-[17px] font-bold">{t("messages.empty.pane.title", "Your messages")}</h2>
                <p className="mx-auto mt-1 max-w-[32ch] text-[13px] text-muted-foreground">{t("messages.empty.pane.text", "Pick a chat on the left, or open a profile you follow and tap the message icon.")}</p>
              </div>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}

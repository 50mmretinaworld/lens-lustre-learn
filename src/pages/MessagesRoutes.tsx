/**
 * /messages/* — the messenger. One screen, three addresses: /messages (list), /messages/<chat id> (a chat),
 * /messages/with/<member id> (start a chat). Wide screens show the list and the chat side by side; a phone
 * shows one at a time. No site footer here (Layout leaves it out): the messenger fills the screen.
 */
import { MessageCircle } from "lucide-react";
import { matchPath, useLocation, useNavigate } from "react-router-dom";
import { useT } from "@/i18n/I18nContext";
import { useAuth } from "@/hooks/core/useAuth";
import { useEffect } from "react";
import ConversationList from "@/components/messages/ConversationList";
import ChatPane from "@/components/messages/ChatPane";
import GroupChatPane from "@/components/messages/GroupChatPane";
import { useConversations } from "@/hooks/messages/useMessages";
import { headingFont } from "@/components/messages/MessageParts";

export default function MessagesRoutes() {
  const t = useT();
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const { user, loading } = useAuth();
  useEffect(() => { if (!loading && !user) navigate("/login", { replace: true }); }, [loading, user, navigate]);

  const withUser = matchPath("/messages/with/:userId", pathname)?.params.userId ?? null;
  const chatId = withUser ? null : (matchPath("/messages/:conversationId", pathname)?.params.conversationId ?? null);
  const hasChat = !!(withUser || chatId);
  const inbox = useConversations("inbox");
  const isGroup = !!chatId && (inbox.data ?? []).some((c) => c.conversationId === chatId && c.kind === "group");

  return (
    <div className="mx-auto h-[calc(100dvh-7.5rem-var(--safe-top)-var(--safe-bottom))] w-full max-w-[1180px] lg:h-[calc(100dvh-6.5rem-var(--safe-top))] lg:px-4 lg:py-3">
      <div className="flex h-full overflow-hidden bg-background lg:rounded-[28px] lg:border lg:border-border lg:shadow-xl lg:shadow-black/10">
        <section aria-label={t("messages.title", "Messages")} className={`${hasChat ? "hidden lg:block" : "block"} h-full w-full shrink-0 lg:w-[380px] lg:border-r lg:border-border`}>
          <ConversationList activeId={chatId} onOpen={(id) => navigate(`/messages/${id}`)} />
        </section>
        <section className={`${hasChat ? "block" : "hidden lg:block"} h-full min-w-0 flex-1`}>
          {hasChat ? (
            isGroup && chatId
              ? <GroupChatPane key={chatId} conversationId={chatId} onBack={() => navigate("/messages")} />
              : <ChatPane key={chatId ?? withUser} conversationId={chatId} userId={withUser} onBack={() => navigate("/messages")} />
          ) : (
            <div className="grid h-full place-items-center bg-gradient-to-b from-background to-muted/30 px-8 text-center">
              <div>
                <span className="mx-auto mb-4 grid h-20 w-20 place-items-center rounded-full bg-gradient-to-br from-primary/15 to-amber-400/15 text-primary"><MessageCircle className="h-9 w-9" /></span>
                <h2 className="text-xl font-bold" style={headingFont}>{t("messages.empty.pane.title", "Your messages")}</h2>
                <p className="mx-auto mt-1.5 max-w-[32ch] text-sm text-muted-foreground">{t("messages.empty.pane.text", "Pick a chat on the left, or open a profile you follow and tap the message icon.")}</p>
              </div>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}

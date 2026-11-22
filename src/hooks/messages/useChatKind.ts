/**
 * Messages · is THIS chat a group or a one-to-one chat? Asked of the chat itself (Owner 22 Nov 2026: the page used
 * to guess from the loaded Inbox list, so a chat opened from a push before the list loaded — or one sitting in
 * Requests — showed in the wrong screen for a moment).
 *  1. a list already loaded (Inbox, Requests, Declined) knows it → answer at once, no request;
 *  2. otherwise the server: message_group_members answers for a group the member is in, and refuses with
 *     MSG-071 for anything that is not their group → one-to-one.
 * Until the answer is in, the page shows a spinner instead of a wrong screen.
 */
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { messageKeys } from "@/lib/messages/keys";
import { fetchGroupMembers } from "@/lib/messages/groups";
import type { ConversationSummary, MessageFolder } from "@/lib/messages/api";

export type ChatKind = "direct" | "group";
const FOLDERS: MessageFolder[] = ["inbox", "requests"];

export function useChatKind(chatId: string | null): ChatKind | null {
  const qc = useQueryClient();
  const { user } = useAuth();
  const known = (): ChatKind | undefined => {
    for (const f of FOLDERS) {
      const hit = qc.getQueryData<ConversationSummary[]>(messageKeys.conversations(user?.id ?? "", f))?.find((c) => c.conversationId === chatId);
      if (hit) return hit.kind;
    }
    return undefined;
  };
  const q = useQuery({
    queryKey: ["messages", "chat-kind", user?.id ?? "", chatId],
    enabled: !!chatId && !!user,
    staleTime: Infinity,
    retry: 1,
    initialData: known,
    queryFn: async (): Promise<ChatKind> => {
      const k = known();
      if (k) return k;
      try {
        await fetchGroupMembers(chatId as string);
        return "group";
      } catch (e) {
        if (e instanceof Error && e.message.includes("MSG-071")) return "direct";
        throw e;
      }
    },
  });
  if (!chatId) return null;
  // a network failure must not leave a blank page: the one-to-one screen shows its own error
  return q.data ?? (q.isError ? "direct" : null);
}

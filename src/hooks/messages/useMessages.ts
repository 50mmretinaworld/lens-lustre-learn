/**
 * Messages · the one store the screens use (React Query over src/lib/messages/api.ts).
 * Screens never call the database or the api functions directly. The server decides
 * who may do what; these hooks only show its answers.
 *
 * Fresh data: a short poll while a screen is open (no websocket yet — a push already
 * tells a member who is away). The polls are slow and stop when the tab is hidden.
 */
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { messageKeys } from "@/lib/messages/keys";
import { useViewAs } from "@/components/messages/viewAs";
import {
  acceptRequest, declineRequest, fetchConversations, fetchThread, fetchViewInbox, fetchViewThread,
  clearConversation, markConversationRead, newClientMsgId, sendMessage, sendPhotos, setConversationMuted,
  type MessageFolder, type SendResult,
} from "@/lib/messages/api";

// The top-bar hook (useMessagingAllowed, first download) and the badge hook are re-exported so the pages import one place.
export { useMessagingAllowed } from "./useMessagingAllowed";
export { useUnreadCounts } from "./useUnreadCounts";

export function useConversations(folder: MessageFolder) {
  const { user, loading } = useAuth();
  const viewAs = useViewAs();   // admin "open a member's message box": the member's list, read-only
  return useQuery({
    queryKey: viewAs ? (["messages", "view-as", viewAs.userId, "conversations", folder] as const) : messageKeys.conversations(user?.id ?? "", folder),
    queryFn: () => (viewAs ? fetchViewInbox(viewAs.userId, folder) : fetchConversations(folder)),
    enabled: !!user && !loading,
    staleTime: 10_000,
    // P10: 30 s while the inbox is open: a new chat from someone else appears without a reload.
    refetchInterval: 30_000,
  });
}

export function useThread(conversationId: string | null) {
  const { user, loading } = useAuth();
  const viewAs = useViewAs();
  return useQuery({
    queryKey: viewAs ? (["messages", "view-as", viewAs.userId, "thread", conversationId ?? ""] as const) : messageKeys.thread(conversationId ?? ""),
    queryFn: () => (viewAs ? fetchViewThread(viewAs.userId, conversationId as string) : fetchThread(conversationId as string)),
    enabled: !!user && !loading && !!conversationId,
    staleTime: 5_000,
    // P10: 30 s (the project floor) and only while one chat is open on screen, so a reply shows up while you
    // are looking at it; the sender's own message appears at once (the send refreshes this query). A push
    // reaches a member who is away. Live delivery over a websocket is a later step.
    refetchInterval: 30_000,
  });
}

function useInvalidateMessages() {
  const qc = useQueryClient();
  return () => {
    void qc.invalidateQueries({ queryKey: ["messages"] });
  };
}

/** One send. The message id is made once per tap (see `start`) so a retry never stores it twice. */
export function useSendMessage() {
  const invalidate = useInvalidateMessages();
  return useMutation<SendResult, Error, { to: string; body: string; clientMsgId: string; replyTo?: number | null }>({
    mutationFn: ({ to, body, clientMsgId, replyTo }) => sendMessage(to, body, clientMsgId, replyTo ?? null),
    onSuccess: invalidate,
  });
}

export function useSendPhotos() {
  const invalidate = useInvalidateMessages();
  return useMutation<SendResult, Error, { to: string; caption: string; clientMsgId: string; photos: Array<{ path: string; width?: number; height?: number }>; replyTo?: number | null }>({
    mutationFn: ({ to, caption, clientMsgId, photos, replyTo }) => sendPhotos(to, caption, clientMsgId, photos, replyTo ?? null),
    onSuccess: invalidate,
  });
}

export function useConversationActions() {
  const invalidate = useInvalidateMessages();
  const accept = useMutation({ mutationFn: acceptRequest, onSuccess: invalidate });
  const decline = useMutation({ mutationFn: declineRequest, onSuccess: invalidate });
  const mute = useMutation({ mutationFn: ({ id, muted }: { id: string; muted: boolean }) => setConversationMuted(id, muted), onSuccess: invalidate });
  const markRead = useMutation({ mutationFn: markConversationRead, onSuccess: invalidate });
  const clear = useMutation({ mutationFn: clearConversation, onSuccess: invalidate });
  return { accept, decline, mute, markRead, clear };
}

export { newClientMsgId };

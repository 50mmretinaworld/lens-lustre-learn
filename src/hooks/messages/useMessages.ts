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
import { queryKeys } from "@/lib/queryKeys";
import {
  acceptRequest, declineRequest, fetchConversations, fetchMessagingAllowed, fetchThread, fetchUnread,
  markConversationRead, newClientMsgId, sendMessage, sendPhotos, setConversationMuted,
  type MessageFolder, type SendResult,
} from "@/lib/messages/api";

/** Whether the Message button / inbox entry should show for this member (the server still refuses a send). */
export function useMessagingAllowed(): boolean {
  const { user, loading } = useAuth();
  const { data } = useQuery({
    queryKey: queryKeys.messageAllowed(user?.id ?? ""),
    queryFn: fetchMessagingAllowed,
    enabled: !!user && !loading,
    staleTime: 60_000,
  });
  return !!user && data === true;
}

export function useUnreadCounts() {
  const { user, loading } = useAuth();
  const q = useQuery({
    queryKey: queryKeys.messageUnread(user?.id ?? ""),
    queryFn: fetchUnread,
    enabled: !!user && !loading,
    staleTime: 15_000,
    // P10: 45 s, only while the tab is visible (react-query pauses hidden tabs). The unread badge is
    // the only live number on the nav; a push covers a member who is away, so a slower poll is enough.
    refetchInterval: 45_000,
  });
  return q.data ?? { inbox: 0, requests: 0 };
}

export function useConversations(folder: MessageFolder) {
  const { user, loading } = useAuth();
  return useQuery({
    queryKey: queryKeys.messageConversations(user?.id ?? "", folder),
    queryFn: () => fetchConversations(folder),
    enabled: !!user && !loading,
    staleTime: 10_000,
    // P10: 30 s while the inbox is open: a new chat from someone else appears without a reload.
    refetchInterval: 30_000,
  });
}

export function useThread(conversationId: string | null) {
  const { user, loading } = useAuth();
  return useQuery({
    queryKey: queryKeys.messageThread(conversationId ?? ""),
    queryFn: () => fetchThread(conversationId as string),
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
  return useMutation<SendResult, Error, { to: string; body: string; clientMsgId: string }>({
    mutationFn: ({ to, body, clientMsgId }) => sendMessage(to, body, clientMsgId),
    onSuccess: invalidate,
  });
}

export function useSendPhotos() {
  const invalidate = useInvalidateMessages();
  return useMutation<SendResult, Error, { to: string; caption: string; clientMsgId: string; photos: Array<{ path: string; width?: number; height?: number }> }>({
    mutationFn: ({ to, caption, clientMsgId, photos }) => sendPhotos(to, caption, clientMsgId, photos),
    onSuccess: invalidate,
  });
}

export function useConversationActions() {
  const invalidate = useInvalidateMessages();
  const accept = useMutation({ mutationFn: acceptRequest, onSuccess: invalidate });
  const decline = useMutation({ mutationFn: declineRequest, onSuccess: invalidate });
  const mute = useMutation({ mutationFn: ({ id, muted }: { id: string; muted: boolean }) => setConversationMuted(id, muted), onSuccess: invalidate });
  const markRead = useMutation({ mutationFn: markConversationRead, onSuccess: invalidate });
  return { accept, decline, mute, markRead };
}

export { newClientMsgId };

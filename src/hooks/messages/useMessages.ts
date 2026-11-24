/**
 * Messages · the one store the screens use (React Query over src/lib/messages/api.ts).
 * Screens never call the database or the api functions directly. The server decides
 * who may do what; these hooks only show its answers.
 *
 * Fresh data: a short poll while a screen is open (no websocket yet — a push already
 * tells a member who is away). The polls are slow and stop when the tab is hidden.
 */
import { useCallback, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { messageKeys } from "@/lib/messages/keys";
import { useViewAs } from "@/components/messages/viewAs";
import { useScreenReady } from "@/lib/screenTiming";
import {
  acceptRequest, declineRequest, fetchConversations, fetchThread, fetchViewInbox, fetchViewThread,
  clearConversation, markConversationRead, newClientMsgId, sendMessage, sendPhotos, setConversationMuted,
  type MessageFolder, type SendResult,
} from "@/lib/messages/api";

/** Is the member on this page right now? (N5: the shared hooks name the screen by its page.) */
const onPage = (re: RegExp): boolean => {
  try { return re.test(window.location.pathname); } catch { return false; }
};

// The top-bar hook (useMessagingAllowed, first download) and the badge hook are re-exported so the pages import one place.
export { useMessagingAllowed } from "./useMessagingAllowed";
export { useUnreadCounts } from "./useUnreadCounts";

/**
 * HOW MANY CHATS THE LIST HOLDS (Owner 24 Nov 2026: "more than 173 msg but showing a few only" — the list asked for
 * 30 and never for more). It starts at 30 (fast first paint) and grows by 50 when the member reaches the end or
 * searches, up to LIST_MAX (the server's cap, SQL 20261124_5400). Always asked FROM THE TOP: paging by time would
 * skip chats that share one instant (a broadcast). Shared by every reader of the same list (module state).
 */
export const LIST_FIRST = 30;
export const LIST_STEP = 50;
export const LIST_MAX = 500;
const listLimit = new Map<string, number>();
const limitKey = (who: string, folder: MessageFolder) => `${who}:${folder}`;
const limitFor = (who: string, folder: MessageFolder) => listLimit.get(limitKey(who, folder)) ?? LIST_FIRST;

function conversationsKey(viewAsUser: string | null, userId: string, folder: MessageFolder) {
  return viewAsUser ? (["messages", "view-as", viewAsUser, "conversations", folder] as const) : messageKeys.conversations(userId, folder);
}

/** The list's "more" control: how many are asked for, and the call to ask for more (from the top). */
export function useConversationsMore(folder: MessageFolder) {
  const { user } = useAuth();
  const viewAs = useViewAs();
  const qc = useQueryClient();
  const who = viewAs ? `view-as:${viewAs.userId}` : user?.id ?? "";
  const [, bump] = useState(0);
  const limit = limitFor(who, folder);
  const more = useCallback((to?: number) => {
    const next = Math.min(LIST_MAX, to ?? limitFor(who, folder) + LIST_STEP);
    if (!who || next <= limitFor(who, folder)) return;
    listLimit.set(limitKey(who, folder), next);
    bump((n) => n + 1);
    void qc.refetchQueries({ queryKey: conversationsKey(viewAs?.userId ?? null, user?.id ?? "", folder), exact: true });
  }, [who, folder, qc, viewAs?.userId, user?.id]);
  return { limit, more };
}

export function useConversations(folder: MessageFolder) {
  const { user, loading } = useAuth();
  const viewAs = useViewAs();   // admin "open a member's message box": the member's list, read-only
  const who = viewAs ? `view-as:${viewAs.userId}` : user?.id ?? "";
  const q = useQuery({
    queryKey: conversationsKey(viewAs?.userId ?? null, user?.id ?? "", folder),
    queryFn: () => (viewAs ? fetchViewInbox(viewAs.userId, folder, limitFor(who, folder)) : fetchConversations(folder, limitFor(who, folder))),
    enabled: !!user && !loading,
    staleTime: 10_000,
    // P10: 30 s while the inbox is open: a new chat from someone else appears without a reload.
    refetchInterval: 30_000,
  });
  // N5: speed per screen — the inbox (its own page, not the list beside an open chat).
  useScreenReady("messages", folder === "inbox" && !viewAs && q.data !== undefined && onPage(/^\/messages\/?$/));
  return q;
}

export function useThread(conversationId: string | null) {
  const { user, loading } = useAuth();
  const viewAs = useViewAs();
  const q = useQuery({
    queryKey: viewAs ? (["messages", "view-as", viewAs.userId, "thread", conversationId ?? ""] as const) : messageKeys.thread(conversationId ?? ""),
    queryFn: () => (viewAs ? fetchViewThread(viewAs.userId, conversationId as string) : fetchThread(conversationId as string)),
    enabled: !!user && !loading && !!conversationId,
    staleTime: 5_000,
    // P10: 30 s (the project floor) and only while one chat is open on screen, so a reply shows up while you
    // are looking at it; the sender's own message appears at once (the send refreshes this query). A push
    // reaches a member who is away. Live delivery over a websocket is a later step.
    refetchInterval: 30_000,
  });
  // N5: speed per screen — one chat open.
  useScreenReady("chat", !viewAs && !!conversationId && q.data !== undefined && onPage(/^\/messages\/[^/]+/));
  return q;
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

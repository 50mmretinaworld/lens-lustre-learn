/**
 * Messages · react-query keys used only by the messages UI (the inbox, a chat, the badge). Kept out of
 * queryKeys.ts so they are not in the first download; the one key the top bar needs (messageAllowed) is
 * there. Every key starts with "messages" so one invalidate refreshes them all.
 */
export const messageKeys = {
  unread: (userId: string) => ["messages", "unread", userId] as const,
  conversations: (userId: string, folder: string) => ["messages", "conversations", userId, folder] as const,
  thread: (conversationId: string) => ["messages", "thread", conversationId] as const,
};

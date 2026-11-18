/**
 * Messages · the two top-bar hooks (entry bundle). Everything else is in useMessages.ts, which only the
 * messages pages import, so it loads with them and not with the first page.
 */
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { queryKeys } from "@/lib/queryKeys";
import { fetchMessagingAllowed, fetchUnread } from "@/lib/messages/nav";

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
  const allowed = useMessagingAllowed();
  const q = useQuery({
    queryKey: queryKeys.messageUnread(user?.id ?? ""),
    queryFn: fetchUnread,
    // only for members the server lets use messages: everyone else never polls
    enabled: !!user && !loading && allowed,
    staleTime: 15_000,
    // P10: 45 s, only while the tab is visible (react-query pauses hidden tabs). The unread badge is
    // the only live number on the nav; a push covers a member who is away, so a slower poll is enough.
    refetchInterval: 45_000,
  });
  return q.data ?? { inbox: 0, requests: 0 };
}

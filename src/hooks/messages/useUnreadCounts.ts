/** Messages · the unread badge hook. Used only by lazy pieces (the messages button, the ☰ sheet, the pages). */
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { messageKeys } from "@/lib/messages/keys";
import { fetchUnread } from "@/lib/messages/unread";
import { useMessagingAllowed } from "./useMessagingAllowed";

export function useUnreadCounts() {
  const { user, loading } = useAuth();
  const allowed = useMessagingAllowed();
  const q = useQuery({
    queryKey: messageKeys.unread(user?.id ?? ""),
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

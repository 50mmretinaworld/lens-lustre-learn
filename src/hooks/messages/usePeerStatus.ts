/**
 * Messages · "Active now" / "Active 12 m ago" for the person in an open chat (Owner 21 Nov: Meta style).
 * Online comes from the site's ONE presence channel (lib/presence/online — it already honours a member who hid their
 * active status). Only when they are NOT online do we ask the server for their last active time (which the server
 * itself withholds for hidden status and for people you share no chat with).
 */
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { useOnline } from "@/lib/presence/online";
import { fetchPeerLastActive } from "@/lib/messages/api";
import { activeAgoText } from "@/lib/messages/format";

export interface PeerStatus { online: boolean; text: string | null }

export function usePeerStatus(userId: string | null | undefined, enabled = true): PeerStatus {
  const { user, loading } = useAuth();
  const online = useOnline(userId);
  const { data } = useQuery({
    queryKey: ["messages", "peer-status", userId ?? ""] as const,
    queryFn: () => fetchPeerLastActive(userId as string),
    enabled: enabled && !!user && !loading && !!userId && !online,
    staleTime: 30_000,
    // P10: 60 s, only while a chat is open on screen and the person is offline; react-query pauses hidden tabs.
    refetchInterval: 60_000,
  });
  if (online) return { online: true, text: "Active now" };
  return { online: false, text: activeAgoText(data) };
}

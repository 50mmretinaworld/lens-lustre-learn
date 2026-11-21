/** Messages · does THIS member have the chat facility too? The profile Message icon shows only when yes. The server still refuses a send. */
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { queryKeys } from "@/lib/queryKeys";
import { fetchCanReachMember } from "@/lib/messages/nav";

export function useCanReachMember(otherUserId: string | undefined): boolean {
  const { user, loading } = useAuth();
  const { data } = useQuery({
    queryKey: queryKeys.messageCanReach(user?.id ?? "", otherUserId ?? ""),
    queryFn: () => fetchCanReachMember(otherUserId as string),
    enabled: !!user && !loading && !!otherUserId && otherUserId !== user.id,
    staleTime: 60_000,
  });
  return !!user && data === true;
}

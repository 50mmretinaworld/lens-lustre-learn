/** Messages · the one top-bar hook (first download): may this member use messages? The server still refuses a send. */
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { queryKeys } from "@/lib/queryKeys";
import { fetchMessagingAllowed } from "@/lib/messages/nav";

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

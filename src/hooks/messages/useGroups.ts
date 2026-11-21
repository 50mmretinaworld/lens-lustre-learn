/** Messages · group chat reads: may I use groups, my friends who can be added, a group's members. The server decides; these only ask. */
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { fetchGroupFriends, fetchGroupMembers, fetchGroupsAllowed } from "@/lib/messages/groups";

export function useGroupsAllowed(): boolean {
  const { user, loading } = useAuth();
  const { data } = useQuery({
    queryKey: ["messages", "groups-allowed", user?.id ?? ""],
    queryFn: fetchGroupsAllowed,
    enabled: !!user && !loading,
    staleTime: 60_000,
  });
  return !!user && data === true;
}

export function useGroupFriends(enabled: boolean) {
  return useQuery({ queryKey: ["messages", "group-friends"], queryFn: fetchGroupFriends, enabled, staleTime: 30_000 });
}

export function useGroupMembers(conversationId: string | null) {
  return useQuery({
    queryKey: ["messages", "group-members", conversationId],
    queryFn: () => fetchGroupMembers(conversationId as string),
    enabled: !!conversationId,
    staleTime: 15_000,
  });
}

export function useRefreshGroupMembers() {
  const qc = useQueryClient();
  return (conversationId: string) => qc.invalidateQueries({ queryKey: ["messages", "group-members", conversationId] });
}

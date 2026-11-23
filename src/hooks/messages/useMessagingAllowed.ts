/** Messages · the one top-bar hook (first download): may this member use messages? The server still refuses a send. */
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { queryKeys } from "@/lib/queryKeys";
import { fetchMessagingAllowed, rememberAllowed, rememberedAllowed } from "@/lib/messages/nav";

export function useMessagingAllowed(): boolean {
  const { user, loading } = useAuth();
  const uid = user?.id ?? "";
  const { data } = useQuery({
    queryKey: queryKeys.messageAllowed(uid),
    // A failed check throws (nav.ts) → the last answer stays; a real answer is remembered on this device.
    queryFn: () => fetchMessagingAllowed().then((ok) => { rememberAllowed(uid, ok); return ok; }),
    enabled: !!user && !loading,
    staleTime: 60_000,
    // The device's last answer shows at once (no icon jumping in on start); it is re-checked straight away.
    initialData: () => (uid ? rememberedAllowed(uid) : undefined),
    initialDataUpdatedAt: 0,
  });
  return !!user && data === true;
}

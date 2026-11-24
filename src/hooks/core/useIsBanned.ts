import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/core/useAuth";
import { queryKeys } from "@/lib/queryKeys";
import { startPart } from "@/lib/appStart";

export function useIsBanned() {
  const { user } = useAuth();

  const { data: isBanned = false, isLoading } = useQuery({
    queryKey: queryKeys.isBanned(user?.id ?? ""),
    queryFn: async () => {
      if (!user) return false;
      // N6-1: at app start the one start-up answer carries the member's own row (same read). null = no row.
      const pre = await startPart<{ is_banned?: boolean | null } | null>("me", user.id, "banned");
      if (pre !== undefined) return pre?.is_banned ?? false;
      const { data } = await supabase
        .from("profiles")
        .select("is_banned")
        .eq("id", user.id)
        .maybeSingle();
      return data?.is_banned ?? false;
    },
    enabled: !!user,
    staleTime: 30_000,
  });

  return { isBanned, isLoading };
}

/** When a member was given one badge ("{month}" in its popup). Only the lazily loaded popup uses it. */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";

export function useBadgeMonth(userId: string | null | undefined, badge: string, enabled: boolean) {
  return useQuery({
    queryKey: ["badge-month", userId ?? "", badge],
    enabled: enabled && !!userId,
    retry: false,
    queryFn: async () => {
      const { data } = await supabase
        .from("user_badges").select("assigned_at").eq("user_id", userId as string).eq("badge_type", badge).maybeSingle();
      return (data as { assigned_at?: string | null } | null)?.assigned_at ?? null;
    },
  });
}

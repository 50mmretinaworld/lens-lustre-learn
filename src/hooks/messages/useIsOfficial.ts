/**
 * Messages · is this member the OFFICIAL account (50mm Retina World — an admin account)? The same rule the server uses for
 * "official → anyone, inbox" (SQL 1200). Owner 22 Nov 2026: the official account cannot be blocked or reported, shows no
 * "Active … ago", and gets no ready-made reply chips.
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";

export function useIsOfficial(userId: string | null | undefined): boolean {
  const { data } = useQuery({
    queryKey: ["messages", "is-official", userId ?? null],
    enabled: !!userId,
    staleTime: 30 * 60_000,
    queryFn: async () => {
      const { data: yes, error } = await (supabase.rpc as unknown as (fn: string, a: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>)(
        "app_has_role", { _user_id: userId, _role: "admin" },
      );
      return !error && yes === true;
    },
  });
  return data === true;
}

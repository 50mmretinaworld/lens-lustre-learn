/**
 * Messages · is this member the OFFICIAL account (50mm Retina World — an admin account)? The same rule the server uses for
 * "official → anyone, inbox" (SQL 1200) and "never blocked / muted" (SQL 4200, 4300).
 * Owner 22 Nov 2026: the official account cannot be blocked, muted, unfollowed or reported; its chat cannot be muted or
 * deleted; it shows no "Active … ago" and gets no ready-made reply chips.
 *
 * ONE rule for the whole app: every menu that offers Block / Mute / Unfollow / Delete chat hides the item through
 * this hook or `<HideForOfficial>` (src/components/messages/HideForOfficial.tsx) — never a check of its own.
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";

/** true = official, false = an ordinary member, undefined = not known yet (do not offer block / mute yet). */
export function useOfficialState(userId: string | null | undefined): boolean | undefined {
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
  return userId ? data : false;
}

export function useIsOfficial(userId: string | null | undefined): boolean {
  return useOfficialState(userId) === true;
}

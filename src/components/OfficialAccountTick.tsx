/**
 * THE OFFICIAL ACCOUNT'S TICK — for places that speak AS 50mm Retina World but carry no member id: sponsored ads,
 * the ad page, the admin broadcast preview.
 *
 * Owner 28 Nov 2026: "Blue badge issues remain same in Ad section … if it changes in one place, all places must
 * show it at one go." Those places drew a fixed BLUE tick by hand, so changing the account to Elite Member never
 * reached them. Now they look up the real official account and draw ITS badge through the one rule every name uses
 * (AutoBadge → UserBadgeInline → VerifiedTick): Elite → gold, Verified → blue, none → nothing.
 *
 * Which account: the server's own rule (get_primary_admin_user_id, signed-in callers); a signed-out visitor, who may
 * not call it, is resolved by the official handle. Nothing is drawn until the account is known — no blue flash
 * before gold.
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { profilesPublic } from "@/lib/profilesPublic";
import AutoBadge from "@/components/AutoBadge";

/** The official account's public handle — used only when the server rule cannot be asked (signed out). */
export const OFFICIAL_HANDLE = "50mmretinaworld";

export function useOfficialAccountId(): string | null {
  const { data } = useQuery({
    queryKey: ["official-account-id"],
    staleTime: 60 * 60_000,
    queryFn: async (): Promise<string | null> => {
      const { data: id, error } = await (supabase.rpc as unknown as (fn: string) => Promise<{ data: unknown; error: unknown }>)(
        "get_primary_admin_user_id",
      );
      if (!error && typeof id === "string" && id) return id;
      const { data: row } = await profilesPublic().select("id").eq("custom_url", OFFICIAL_HANDLE).maybeSingle();
      const pid = (row as { id?: unknown } | null)?.id;
      return typeof pid === "string" && pid ? pid : null;
    },
  });
  return data ?? null;
}

export default function OfficialAccountTick({ size = "compact" }: { size?: "compact" | "full" }) {
  const id = useOfficialAccountId();
  return id ? <AutoBadge userId={id} size={size} only="verified" /> : null;
}

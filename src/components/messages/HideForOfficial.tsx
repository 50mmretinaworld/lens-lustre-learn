import type { ReactNode } from "react";
import { useOfficialState } from "@/hooks/messages/useIsOfficial";

/**
 * Shows its children only once the member is KNOWN not to be the official 50mm Retina World account (Owner 22 Nov 2026:
 * nobody can block, mute or unfollow it). Place it inside a menu's content — that mounts only when the menu opens — so
 * the check runs only when someone opens the menu. The server refuses these actions as well (SQL 4200 / 4300).
 */
export default function HideForOfficial({ userId, children }: { userId: string | null | undefined; children: ReactNode }) {
  return useOfficialState(userId) === false ? <>{children}</> : null;
}

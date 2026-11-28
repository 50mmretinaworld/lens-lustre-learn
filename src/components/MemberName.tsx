import type { ReactNode } from "react";
import AutoBadge from "@/components/AutoBadge";

/**
 * THE piece for a member's name in a line of text: the name, then that member's badge (blue tick, or gold for
 * Elite), looked up by id from the one shared profile cache (AutoBadge → useProfileMap, micro-batched, so a list of
 * fifty names is one request).
 *
 * Owner 28 Nov 2026: "Name with Badge centrally … if it changes in one place, all places must show at one go".
 * Use this (or UserIdentityBlock when there is an avatar + handle) wherever a member's name is printed. The ratchet
 * src/__tests__/nameCarriesBadge.test.ts fails on a name printed any other way.
 *
 * `children` replaces the plain name text when the caller needs its own wrapper (bold, link, truncate) around it;
 * the badge is still drawn here, so no caller can forget it.
 */
export default function MemberName({
  userId,
  name,
  children,
  className,
}: {
  userId: string | null | undefined;
  name?: string | null;
  children?: ReactNode;
  className?: string;
}) {
  return (
    <>
      {children ?? (
        <span data-member-name="" className={className}>
          {name}
        </span>
      )}
      {userId ? (
        // The gap lives on this box, not in a text space: when the member holds no badge the box is empty and
        // `empty:hidden` removes it, so "Name, Name" never reads "Name , Name".
        <span className="ms-1 inline-flex align-middle empty:hidden">
          <AutoBadge userId={userId} only="verified" />
        </span>
      ) : null}
    </>
  );
}

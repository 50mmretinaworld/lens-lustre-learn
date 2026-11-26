/**
 * THE BLUE VERIFIED TICK — the ONE place it is drawn with its message
 * (Premium Members Part 2, Owner-approved tick message, 26 Nov 2026).
 *
 * Tap / click the tick → a small card (VerifiedTickCard, loaded only on the
 * first tap so the first download does not grow):
 *   "Verified Photographer"
 *   "{Name} was honoured by the 50mm Retina World curators in {Mon YYYY}.
 *    This tick cannot be requested or bought."
 *   "See all Verified Photographers" → /premium-members
 *
 * The 50mm brand / admin account keeps its tick exactly as before (hover
 * tooltip): its tick is the brand's, not an honour, and it is never on the
 * Premium Members page.
 *
 * The tick often sits INSIDE a link that wraps the member's name. The tap is
 * stopped here (preventDefault + stopPropagation) so it opens the card and
 * never also follows the name's link; the card itself stops its clicks too.
 *
 * Without a member id (a caller that only has the badge list) the tick is drawn
 * plain — there is no name to put in the sentence.
 */
import { lazy, Suspense, useCallback, useRef, useState } from "react";
import type React from "react";
import VerifiedBadge from "@/components/VerifiedBadge";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useAdminIds } from "@/hooks/core/useAdminIds";

const VerifiedTickCard = lazy(() => import("@/components/premium/VerifiedTickCard"));

/** The brand account's tooltip — unchanged wording, brand/admin only. */
export const BRAND_TICK_TOOLTIP = "✓ Verified Profile — Authenticated identity";

interface Props {
  userId?: string | null;
  name?: string | null;
  className?: string;
}

const BrandTick = ({ className }: { className: string }) => (
  <Tooltip>
    <TooltipTrigger asChild>
      <span className="inline-flex shrink-0 cursor-default">
        <VerifiedBadge className={className} />
      </span>
    </TooltipTrigger>
    <TooltipContent side="bottom" className="text-xs font-medium px-3 py-2 max-w-[220px]">
      {BRAND_TICK_TOOLTIP}
    </TooltipContent>
  </Tooltip>
);

const MemberTick = ({ userId, name, className }: { userId: string; name?: string | null; className: string }) => {
  const admins = useAdminIds();
  const trigger = useRef<HTMLSpanElement>(null);
  const [anchor, setAnchor] = useState<DOMRect | null>(null);

  const close = useCallback(() => setAnchor(null), []);
  const toggle = (e: React.SyntheticEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setAnchor((open) => (open ? null : trigger.current?.getBoundingClientRect() ?? null));
  };

  if (admins.has(userId)) return <BrandTick className={className} />;

  return (
    <>
      <span
        ref={trigger}
        role="button"
        tabIndex={0}
        aria-label="Verified Photographer"
        aria-expanded={!!anchor}
        onClick={toggle}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") toggle(e);
        }}
        className="inline-flex shrink-0 cursor-pointer"
      >
        <VerifiedBadge className={className} />
      </span>
      {anchor && (
        <Suspense fallback={null}>
          <VerifiedTickCard userId={userId} name={name} anchor={anchor} trigger={trigger} onClose={close} />
        </Suspense>
      )}
    </>
  );
};

const VerifiedTick = ({ userId, name, className = "h-4 w-4" }: Props) =>
  userId ? <MemberTick userId={userId} name={name} className={className} /> : <VerifiedBadge className={`${className} shrink-0`} />;

export default VerifiedTick;

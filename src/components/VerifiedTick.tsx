/**
 * THE BLUE VERIFIED TICK — the ONE place it is drawn with its message
 * (Premium Members Part 2, Owner-approved tick message, 26 Nov 2026).
 *
 * Tap / click the tick → a small card (VerifiedTickCard):
 *   "Verified Photographer"
 *   "{Name} was honoured by the 50mm Retina World curators in {Mon YYYY}.
 *    This tick cannot be requested or bought."
 *   "See all Verified Photographers" → /premium-members
 *
 * The tick often sits INSIDE a link that wraps the member's name. The tap is
 * stopped (preventDefault + stopPropagation) so it opens the card and never
 * also follows the name's link; the card itself stops its clicks too.
 *
 * Only this shell is in the first download (P13 byte ceiling). The tappable
 * tick (VerifiedTickMember) loads when a named tick is first drawn; until it
 * arrives, or if it cannot load, the same tick is drawn plain. Without a member
 * id there is no name for the sentence, so the tick is always plain.
 */
import { lazy, Suspense } from "react";
import VerifiedBadge from "@/components/VerifiedBadge";

interface Props {
  userId?: string | null;
  name?: string | null;
  className?: string;
  /** The gold Elite Member tick (Owner 27 Nov 2026) instead of the blue Verified one. */
  gold?: boolean;
}

// userId / name accepted (and unused) so it can stand in for VerifiedTickMember.
const PlainTick = ({ className, gold }: { className: string; userId?: string; name?: string | null; gold?: boolean }) => <VerifiedBadge className={`${className} shrink-0`} gold={gold} />;

// A failed load must never take the name row's screen down with it.
const VerifiedTickMember = lazy(() =>
  import("@/components/premium/VerifiedTickMember").catch(() => ({ default: PlainTick })),
);

const VerifiedTick = ({ userId, name, className = "h-4 w-4", gold }: Props) => {
  const plain = <PlainTick className={className} gold={gold} />;
  return userId ? (
    <Suspense fallback={plain}>
      <VerifiedTickMember userId={userId} name={name} className={className} gold={gold} />
    </Suspense>
  ) : (
    plain
  );
};

export default VerifiedTick;

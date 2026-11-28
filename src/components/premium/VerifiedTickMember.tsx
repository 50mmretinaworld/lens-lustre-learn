/**
 * A MEMBER'S tick — blue Verified or gold Elite Member: mouse over / tap → its popup. Loaded by
 * VerifiedTick when a named tick is first drawn, so none of this rides in the
 * first download (P13 byte ceiling).
 *
 * The 50mm brand / admin account keeps its tick exactly as before (hover
 * tooltip): its tick is the brand's, not an honour, and it is never on the
 * Premium Members page.
 */
import VerifiedBadge from "@/components/VerifiedBadge";
import BadgeCardTrigger from "@/components/badges/BadgeCardTrigger";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useAdminIds } from "@/hooks/core/useAdminIds";

/** The brand account's tooltip — unchanged wording, brand/admin only. */
export const BRAND_TICK_TOOLTIP = "✓ Verified Profile — Authenticated identity";

interface Props {
  userId: string;
  name?: string | null;
  className: string;
  gold?: boolean;
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

const VerifiedTickMember = ({ userId, name, className, gold }: Props) => {
  const admins = useAdminIds();

  // The brand tick is the official account's BLUE tick; once an admin gives it Elite Member, gold wins there too
  // (Owner bug list 27 Nov, item 3: one rule for every member).
  if (admins.has(userId) && !gold) return <BrandTick className={className} />;

  return (
    <BadgeCardTrigger
      badge={gold ? "elite_member" : "verified"}
      userId={userId}
      name={name}
      label={gold ? "Elite Member" : "Verified Photographer"}
      className="inline-flex shrink-0"
    >
      <VerifiedBadge className={className} gold={gold} />
    </BadgeCardTrigger>
  );
};

export default VerifiedTickMember;

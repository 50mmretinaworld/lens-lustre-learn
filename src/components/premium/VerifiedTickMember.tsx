/**
 * A MEMBER'S blue tick: tap → the Verified Photographer card. Loaded by
 * VerifiedTick when a named tick is first drawn, so none of this rides in the
 * first download (P13 byte ceiling).
 *
 * The 50mm brand / admin account keeps its tick exactly as before (hover
 * tooltip): its tick is the brand's, not an honour, and it is never on the
 * Premium Members page.
 */
import { useCallback, useRef, useState } from "react";
import type React from "react";
import VerifiedBadge from "@/components/VerifiedBadge";
import VerifiedTickCard from "@/components/premium/VerifiedTickCard";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useAdminIds } from "@/hooks/core/useAdminIds";

/** The brand account's tooltip — unchanged wording, brand/admin only. */
export const BRAND_TICK_TOOLTIP = "✓ Verified Profile — Authenticated identity";

interface Props {
  userId: string;
  name?: string | null;
  className: string;
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

const VerifiedTickMember = ({ userId, name, className }: Props) => {
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
      {anchor && <VerifiedTickCard userId={userId} name={name} anchor={anchor} trigger={trigger} onClose={close} />}
    </>
  );
};

export default VerifiedTickMember;

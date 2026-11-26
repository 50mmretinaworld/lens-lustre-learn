/**
 * The small card the blue tick opens (VerifiedTick). Loaded on the first tap.
 * Same card on web and app; wording from src/lib/premium/premiumMember.ts.
 *
 * Placed under the tick (above it when there is no room below), kept inside
 * the screen with a 16 px gutter, at most 320 px wide. Closes on a tap outside,
 * Escape, scrolling, or following its link.
 *
 * Rendered into <body>, but React still bubbles its clicks through the tick's
 * parents — which are often a link around the member's name. Every click on the
 * card is stopped here so it never also opens that link.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type React from "react";
import { createPortal } from "react-dom";
import { Link } from "react-router-dom";
import VerifiedBadge from "@/components/VerifiedBadge";
import { useMemberName } from "@/hooks/profile/useMemberName";
import { useVerifiedHonour } from "@/hooks/profile/usePremiumHonour";
import { PREMIUM_MEMBERS_PATH, VERIFIED_CARD_LINK_TEXT, VERIFIED_CARD_TITLE, verifiedTickMessage } from "@/lib/premium/premiumMember";

interface Props {
  userId: string;
  name?: string | null;
  anchor: DOMRect;
  trigger: React.RefObject<HTMLElement | null>;
  onClose: () => void;
}

const GUTTER = 16;
const MAX_W = 320;

function place(anchor: DOMRect, height: number): React.CSSProperties {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const width = Math.min(MAX_W, vw - GUTTER * 2);
  const left = Math.min(Math.max(anchor.left + anchor.width / 2 - width / 2, GUTTER), vw - width - GUTTER);
  const below = anchor.bottom + 8;
  const top = below + height > vh - GUTTER && anchor.top - 8 - height > GUTTER ? anchor.top - 8 - height : below;
  return { position: "fixed", top, left, width, zIndex: 80 };
}

const VerifiedTickCard = ({ userId, name, anchor, trigger, onClose }: Props) => {
  const card = useRef<HTMLDivElement>(null);
  const known = useMemberName(userId, name);
  const { data: honour, isLoading } = useVerifiedHonour(userId);
  const [height, setHeight] = useState(150);

  useLayoutEffect(() => {
    if (card.current) setHeight(card.current.offsetHeight);
  }, [known, honour]);

  useEffect(() => {
    card.current?.focus({ preventScroll: true });
    const outside = (e: PointerEvent) => {
      const t = e.target as Node | null;
      if (t && (card.current?.contains(t) || trigger.current?.contains(t))) return;
      onClose();
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("pointerdown", outside, true);
    document.addEventListener("keydown", key);
    window.addEventListener("scroll", onClose, { passive: true, capture: true });
    window.addEventListener("resize", onClose);
    return () => {
      document.removeEventListener("pointerdown", outside, true);
      document.removeEventListener("keydown", key);
      window.removeEventListener("scroll", onClose, { capture: true });
      window.removeEventListener("resize", onClose);
    };
  }, [onClose, trigger]);

  const stop = (e: React.SyntheticEvent) => e.stopPropagation();
  const ready = !!known && !isLoading;

  return createPortal(
    <div
      ref={card}
      role="dialog"
      aria-label={VERIFIED_CARD_TITLE}
      tabIndex={-1}
      data-testid="verified-tick-card"
      onClick={stop}
      onPointerDown={stop}
      onKeyDown={stop}
      style={place(anchor, height)}
      className="flex flex-col gap-2 rounded-2xl border border-border bg-card p-4 text-card-foreground shadow-xl outline-none"
    >
      <span className="flex items-center gap-2 text-[17px] font-bold leading-tight">
        <VerifiedBadge className="shrink-0" style={{ width: 22, height: 22 }} aria-hidden />
        {VERIFIED_CARD_TITLE}
      </span>
      {ready ? (
        <p className="text-[15px] leading-snug text-muted-foreground">{verifiedTickMessage(known, honour?.assignedAt)}</p>
      ) : (
        <span aria-busy="true" className="block h-10 w-full animate-pulse rounded bg-muted" />
      )}
      <Link to={PREMIUM_MEMBERS_PATH} onClick={onClose} className="text-[15px] font-semibold text-primary hover:underline">
        {VERIFIED_CARD_LINK_TEXT}
      </Link>
    </div>,
    document.body,
  );
};

export default VerifiedTickCard;

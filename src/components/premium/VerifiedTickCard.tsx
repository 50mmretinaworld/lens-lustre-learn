/**
 * THE ONE badge / role popup: icon + bold heading, and the message lined up under the heading
 * (Owner-approved sample, 27 Nov 2026). The blue tick, the gold Elite Member tick and every badge and
 * role open this card. Loaded on the first tap / hover. Same on web and app. Heading and message are
 * written by Admin (badge_definitions / role_display_config); defaults in src/lib/badges/badgeText.ts.
 *
 * Placed under the badge (above it when there is no room below), kept inside
 * the screen with a 16 px gutter, at most 320 px wide. Closes on a tap outside,
 * Escape, scrolling, or following its link.
 *
 * Rendered into <body>, but React still bubbles its clicks through the badge's
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
import { useBadgeMonth } from "@/hooks/profile/useBadgeMonth";
import { useBadgeDefinitions } from "@/hooks/profile/useBadgeDefinitions";
import { useRoleDefinitions } from "@/hooks/profile/useRoleDefinitions";
import { PREMIUM_MEMBERS_PATH, VERIFIED_CARD_LINK_TEXT, honouredLabel } from "@/lib/premium/premiumMember";
import { fillPopupText, popupTemplate, popupTitle } from "@/lib/badges/badgeText";

interface Props {
  userId?: string | null;
  name?: string | null;
  anchor: DOMRect;
  trigger: React.RefObject<HTMLElement | null>;
  onClose: () => void;
  /** badge_definitions.type_key, or role_display_config.role_key with `role`. */
  badge?: string;
  role?: boolean;
  /** Opened by hover: leave the keyboard focus where it is. */
  hover?: boolean;
  onPointerEnter?: () => void;
  onPointerLeave?: () => void;
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

type TextProps = { template: string; userId?: string | null; name: string | null; badge: string };

const Waiting = () => <span aria-busy="true" className="block h-10 w-full animate-pulse rounded bg-muted" />;

const Message = ({ template, name, at }: { template: string; name: string | null; at: string | null | undefined }) => (
  <p className="whitespace-pre-line text-[15px] leading-snug text-muted-foreground">
    {fillPopupText(template, name || "This member", honouredLabel(at))}
  </p>
);

/** The blue tick's month comes from the same honour read the ⋯ menu uses. */
const VerifiedText = ({ template, userId, name }: TextProps) => {
  const { data, isLoading } = useVerifiedHonour(userId);
  return !name || isLoading ? <Waiting /> : <Message template={template} name={name} at={data?.assignedAt} />;
};

const BadgeText = ({ template, userId, name, badge }: TextProps) => {
  const needsMonth = !!userId && template.includes("{month}");
  const { data, isLoading } = useBadgeMonth(userId, badge, needsMonth);
  const waiting = (!!userId && !name && template.includes("{name}")) || (needsMonth && isLoading);
  return waiting ? <Waiting /> : <Message template={template} name={name} at={data} />;
};

const VerifiedTickCard = ({ userId, name, anchor, trigger, onClose, badge = "verified", role = false, hover, onPointerEnter, onPointerLeave }: Props) => {
  const card = useRef<HTMLDivElement>(null);
  const known = useMemberName(userId ?? "", name) ?? null;
  const badgeDefs = useBadgeDefinitions();
  const roleDefs = useRoleDefinitions();
  const def = role ? roleDefs.get(badge) : badgeDefs.get(badge);
  const title = popupTitle(badge, def?.label ?? "", def?.popup_title);
  const template = popupTemplate(badge, role, def?.popup_message);
  const tick = !role && (badge === "verified" || badge === "elite_member");
  const [height, setHeight] = useState(150);

  useLayoutEffect(() => {
    if (card.current) setHeight(card.current.offsetHeight);
  });

  useEffect(() => {
    if (!hover) card.current?.focus({ preventScroll: true });
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
  }, [onClose, trigger, hover]);

  const stop = (e: React.SyntheticEvent) => e.stopPropagation();
  const text = { template, userId, name: known, badge };

  return createPortal(
    <div
      ref={card}
      role="dialog"
      aria-label={title}
      tabIndex={-1}
      data-testid="verified-tick-card"
      onClick={stop}
      onPointerDown={stop}
      onKeyDown={stop}
      onPointerEnter={onPointerEnter}
      onPointerLeave={onPointerLeave}
      style={place(anchor, height)}
      className="grid grid-cols-[auto_1fr] items-center gap-x-2 gap-y-2 rounded-2xl border border-border bg-card p-4 text-left font-normal normal-case tracking-normal text-card-foreground shadow-xl outline-none"
    >
      <span className="flex w-[22px] items-center justify-center text-lg leading-none" aria-hidden>
        {tick ? <VerifiedBadge gold={badge === "elite_member"} style={{ width: 22, height: 22 }} /> : def?.icon}
      </span>
      <span className="text-[17px] font-bold leading-tight">{title}</span>
      <div className="col-start-2 flex flex-col gap-2">
        {badge === "verified" && !role ? <VerifiedText {...text} /> : <BadgeText {...text} />}
        {badge === "verified" && !role && (
          <Link to={PREMIUM_MEMBERS_PATH} onClick={onClose} className="text-[15px] font-semibold text-primary hover:underline">
            {VERIFIED_CARD_LINK_TEXT}
          </Link>
        )}
      </div>
    </div>,
    document.body,
  );
};

export default VerifiedTickCard;

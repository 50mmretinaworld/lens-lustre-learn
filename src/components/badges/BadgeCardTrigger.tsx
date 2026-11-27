/**
 * Wraps a badge, role or tick: mouse over on a computer, tap on a phone → the popup (VerifiedTickCard).
 * The badge often sits INSIDE a link around the member's name, so the tap is stopped here and never
 * also follows that link.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type React from "react";
import VerifiedTickCard from "@/components/premium/VerifiedTickCard";

interface Props {
  badge: string;
  role?: boolean;
  userId?: string | null;
  name?: string | null;
  label: string;
  className: string;
  children: React.ReactNode;
}

/** Long enough to move the mouse from the badge into the card. */
const LEAVE_MS = 200;

const BadgeCardTrigger = ({ badge, role, userId, name, label, className, children }: Props) => {
  const trigger = useRef<HTMLSpanElement>(null);
  const [open, setOpen] = useState<{ anchor: DOMRect; hover: boolean } | null>(null);
  const timer = useRef<number>(0);

  const keep = useCallback(() => window.clearTimeout(timer.current), []);
  const close = useCallback(() => {
    keep();
    setOpen(null);
  }, [keep]);
  useEffect(() => keep, [keep]);

  const show = (hover: boolean) => {
    const anchor = trigger.current?.getBoundingClientRect();
    if (anchor) setOpen({ anchor, hover });
  };
  const enter = (e: React.PointerEvent) => {
    if (e.pointerType !== "mouse") return;
    keep();
    if (!open) show(true);
  };
  const leave = (e?: React.PointerEvent) => {
    if (e && e.pointerType !== "mouse") return;
    if (!open?.hover) return;
    keep();
    timer.current = window.setTimeout(() => setOpen(null), LEAVE_MS);
  };
  const press = (e: React.SyntheticEvent) => {
    e.preventDefault();
    e.stopPropagation();
    keep();
    // A click on a card opened by hover keeps it open; a second tap / click closes it.
    if (open && !open.hover) setOpen(null);
    else show(false);
  };

  return (
    <>
      <span
        ref={trigger}
        role="button"
        tabIndex={0}
        aria-label={label}
        aria-expanded={!!open}
        onClick={press}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") press(e);
        }}
        onPointerEnter={enter}
        onPointerLeave={leave}
        className={`${className} cursor-pointer`}
      >
        {children}
      </span>
      {open && (
        <VerifiedTickCard
          badge={badge}
          role={role}
          userId={userId}
          name={name}
          hover={open.hover}
          anchor={open.anchor}
          trigger={trigger}
          onClose={close}
          onPointerEnter={keep}
          onPointerLeave={() => leave()}
        />
      )}
    </>
  );
};

export default BadgeCardTrigger;

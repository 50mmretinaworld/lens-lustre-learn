/**
 * Only this shell is in the first download (P13 byte ceiling). The popup's code loads when a badge is
 * first drawn; until then, or if it cannot load, the badge is drawn plain.
 */
import { lazy, Suspense } from "react";
import type { ComponentProps } from "react";
import type BadgeCardTrigger from "@/components/badges/BadgeCardTrigger";

type Props = ComponentProps<typeof BadgeCardTrigger>;

const Plain = ({ className, children }: Props) => <span className={className}>{children}</span>;

// A failed load must never take the name row's screen down with it.
const Trigger = lazy(() => import("@/components/badges/BadgeCardTrigger").catch(() => ({ default: Plain })));

const LazyBadgeTrigger = (props: Props) => (
  <Suspense fallback={<Plain {...props} />}>
    <Trigger {...props} />
  </Suspense>
);

export default LazyBadgeTrigger;

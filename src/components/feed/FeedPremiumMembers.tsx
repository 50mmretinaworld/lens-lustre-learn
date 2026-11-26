import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { ChevronLeft, ChevronRight } from "lucide-react";
import VerifiedBadge from "@/components/VerifiedBadge";
import PremiumMemberCard from "@/components/premium/PremiumMemberCard";
import { usePremiumFollow } from "@/components/premium/usePremiumFollow";
import { usePremiumMembers } from "@/hooks/feed/usePremiumMembers";

/**
 * "MEET OUR PREMIUM MEMBERS" — the feed row (Owner-approved plan, Parts 3 + 7).
 *
 * Directly below the Trending card (FEED_INSERTS.trending). Unlike Trending it
 * shows at EVERY width: phone, app and the computer's centre column. The same
 * scroller and arrows as People You May Know (FeedFriendSuggestions), with the
 * ONE PremiumMemberCard the /premium-members page also uses. Nothing at all
 * when the list is empty (or the server function is not there yet).
 */

/** Card width (210) + the gap between cards (gap-2.5 = 10px). One tap = one card. */
const CARD_STEP = 220;
/** Fractional scroll offsets: slack before "there is more this way" turns off. */
const EDGE_SLACK = 4;

const headingFont = { fontFamily: "var(--font-heading)" };
const bodyFont = { fontFamily: "var(--font-body)" };

export default function FeedPremiumMembers() {
  const { data: members = [] } = usePremiumMembers();
  const { isFollowing, follow, busyId, prompt, selfId } = usePremiumFollow(members);

  const railRef = useRef<HTMLDivElement | null>(null);
  const [canLeft, setCanLeft] = useState(false);
  const [canRight, setCanRight] = useState(false);
  const measure = useCallback(() => {
    const el = railRef.current;
    if (!el) return;
    setCanLeft(el.scrollLeft > EDGE_SLACK);
    setCanRight(el.scrollLeft + el.clientWidth < el.scrollWidth - EDGE_SLACK);
  }, []);
  useLayoutEffect(() => {
    const el = railRef.current;
    if (!el) return;
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [measure, members.length]);
  const nudge = (dir: -1 | 1) => railRef.current?.scrollBy({ left: dir * CARD_STEP, behavior: "smooth" });

  if (members.length === 0) return null;

  const arrow = "absolute top-[140px] -translate-y-1/2 flex h-11 w-11 items-center justify-center";
  const arrowFace = "flex h-8 w-8 items-center justify-center rounded-full border border-border bg-background/95 text-foreground shadow-sm active:scale-95 transition-transform";

  return (
    <section
      className="bleed-phone overflow-hidden mb-4 border-b border-border md:rounded-lg md:border"
      aria-label="Meet our Premium Members"
      data-testid="feed-premium-members"
    >
      <div className="flex items-start justify-between gap-3 px-4 pt-3.5 pb-2">
        <div className="min-w-0">
          <h2 className="flex items-center gap-1.5 text-[15px] font-bold text-foreground" style={headingFont}>
            <VerifiedBadge className="h-5 w-5 shrink-0" aria-hidden="true" />
            Meet our Premium Members
          </h2>
          <p className="mt-0.5 text-[13px] text-muted-foreground" style={bodyFont}>Honoured by our curators</p>
        </div>
        <Link
          to="/premium-members"
          className="-mt-2 inline-flex min-h-11 shrink-0 items-center text-sm font-semibold text-primary hover:underline"
          style={headingFont}
        >
          See all
        </Link>
      </div>

      <div className="relative">
        <div
          ref={railRef}
          onScroll={measure}
          className="flex gap-2.5 overflow-x-auto overscroll-x-contain snap-x snap-mandatory scroll-px-4 scrollbar-hide px-4 pb-4 pt-1"
        >
          {members.map((m) => (
            <PremiumMemberCard
              key={m.user_id}
              member={m}
              following={isFollowing(m.user_id)}
              self={m.user_id === selfId}
              busy={busyId === m.user_id}
              onFollow={follow}
              className="w-[210px] shrink-0 snap-start"
            />
          ))}
        </div>
        {canLeft && (
          <>
            <div className="pointer-events-none absolute left-0 top-0 bottom-4 w-10 bg-gradient-to-r from-background to-transparent" />
            <button type="button" onClick={() => nudge(-1)} aria-label="Previous Premium Members" className={`${arrow} left-0`}>
              <span className={arrowFace}><ChevronLeft className="h-4 w-4" /></span>
            </button>
          </>
        )}
        {canRight && (
          <>
            <div className="pointer-events-none absolute right-0 top-0 bottom-4 w-10 bg-gradient-to-l from-background to-transparent" />
            <button type="button" onClick={() => nudge(1)} aria-label="More Premium Members" className={`${arrow} right-0`}>
              <span className={arrowFace}><ChevronRight className="h-4 w-4" /></span>
            </button>
          </>
        )}
      </div>
      {prompt}
    </section>
  );
}

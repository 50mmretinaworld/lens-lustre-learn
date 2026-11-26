import { Heart } from "lucide-react";
import ProfileLink from "@/components/ProfileLink";
import UserBadgeInline from "@/components/UserBadgeInline";
import OptimizedImage from "@/components/OptimizedImage";
import PresenceAvatar from "@/components/PresenceAvatar";
import { honouredLabel, premiumPhotoSrc } from "@/lib/premium/premiumMember";
import type { PremiumMember } from "@/hooks/feed/usePremiumMembers";

/**
 * THE ONE PREMIUM MEMBER CARD (Owner-approved plan, 26 Nov 2026, Parts 3 + 4).
 *
 * Used by BOTH the feed row and the /premium-members page — one component per
 * concept (central-control rule). The parent decides the width; the card is
 * photo 4:5, round avatar over the photo's bottom-left, name + blue tick, the
 * line (curator's citation in italics, bio line plain, nothing when none),
 * "Honoured {Mon YYYY}" and Follow / Following. No follower count.
 */

const headingFont = { fontFamily: "var(--font-heading)" };
const bodyFont = { fontFamily: "var(--font-body)" };
const VERIFIED = ["verified"];

interface Props {
  member: PremiumMember;
  following: boolean;
  /** The viewer is this member: no Follow button on their own card. */
  self?: boolean;
  busy?: boolean;
  onFollow: (m: PremiumMember) => void;
  className?: string;
}

export default function PremiumMemberCard({ member: m, following, self = false, busy = false, onFollow, className = "" }: Props) {
  const photo = premiumPhotoSrc(m);
  const honoured = honouredLabel(m.honoured_at);

  return (
    <article
      data-testid="premium-member-card"
      className={`flex flex-col overflow-hidden rounded-xl bg-card ${className}`}
    >
      <div className="relative">
        <ProfileLink userId={m.user_id} handle={m.handle} aria-label={`${m.full_name} — profile`} className="block">
          {photo ? (
            <OptimizedImage src={photo} alt={`Photograph by ${m.full_name}`} loading="lazy" className="aspect-[4/5] w-full object-cover" />
          ) : (
            <div className="aspect-[4/5] w-full bg-muted" aria-hidden="true" />
          )}
        </ProfileLink>
        {/* the shared avatar (PresenceAvatar: photo, else initial); no online dot on this card */}
        <span className="absolute -bottom-4 left-2.5 rounded-full bg-card p-0.5" aria-hidden="true">
          <PresenceAvatar src={m.avatar_url} name={m.full_name} size={36} showRing={false} showDot={false} />
        </span>
      </div>

      <div className="flex flex-1 flex-col gap-1 px-3 pb-3 pt-6">
        <div className="flex min-w-0 items-center gap-1">
          <ProfileLink
            userId={m.user_id}
            handle={m.handle}
            className="min-w-0 truncate text-[15px] font-bold leading-tight text-foreground hover:underline"
            style={headingFont}
          >
            {m.full_name}
          </ProfileLink>
          <span className="shrink-0">
            <UserBadgeInline badges={VERIFIED} only="verified" />
          </span>
        </div>
        {m.line && (
          <p
            data-testid="premium-line"
            data-citation={m.line_is_citation ? "true" : "false"}
            className={`line-clamp-2 text-[13px] leading-snug text-foreground/75 ${m.line_is_citation ? "italic" : ""}`}
            style={bodyFont}
          >
            {m.line}
          </p>
        )}
        {honoured && (
          <p className="text-xs text-muted-foreground" style={bodyFont}>
            Honoured {honoured}
          </p>
        )}
        {/* the spacer keeps Follow on one line across a row of cards with and without a line */}
        <span className="flex-1" aria-hidden="true" />
        {!self && (
          <button
            type="button"
            onClick={() => onFollow(m)}
            disabled={busy}
            aria-pressed={following}
            aria-label={following ? `Following ${m.full_name}` : `Follow ${m.full_name}`}
            className={`mt-1 inline-flex h-11 w-full items-center justify-center gap-1.5 rounded-lg text-sm font-semibold transition-colors disabled:opacity-60 ${
              following
                ? "border border-border bg-transparent text-foreground hover:bg-muted"
                : "bg-primary text-primary-foreground hover:opacity-90"
            }`}
            style={headingFont}
          >
            <Heart className={`h-4 w-4 ${following ? "fill-current" : ""}`} aria-hidden="true" />
            {following ? "Following" : "Follow"}
          </button>
        )}
      </div>
    </article>
  );
}

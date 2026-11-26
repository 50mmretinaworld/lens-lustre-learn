import { useEffect, useRef, useState, type CSSProperties } from "react";
import { Heart } from "lucide-react";
import { photoBlurFor, requestPhotoBlurs, usePhotoBlurVersion } from "@/lib/photoBlur";
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
/** One-off sizes as inline styles: no new rules in the one shared stylesheet (P13 initial budget). */
const AVATAR_POS = { bottom: -16 };

interface Props {
  style?: CSSProperties;
  member: PremiumMember;
  following: boolean;
  /** The viewer is this member: no Follow button on their own card. */
  self?: boolean;
  busy?: boolean;
  onFollow: (m: PremiumMember) => void;
  className?: string;
}

export default function PremiumMemberCard({ member: m, following, self = false, busy = false, onFollow, className = "", style }: Props) {
  const photo = premiumPhotoSrc(m);
  const honoured = honouredLabel(m.honoured_at);

  /*
   * BLUR → SHARP with the EXISTING ThumbHash codes (lib/photoBlur.ts, as PostMedia):
   * one batched read per tick for every card on screen, keyed by the stored
   * photo address; the code is drawn behind, the sharp copy fades in on load.
   */
  usePhotoBlurVersion();
  useEffect(() => {
    if (m.post_id && m.photo_url) requestPhotoBlurs(m.post_id, [m.photo_url]);
  }, [m.post_id, m.photo_url]);
  const blur = photoBlurFor(m.photo_url);
  const box = useRef<HTMLDivElement | null>(null);
  const [sharp, setSharp] = useState(false);
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const img = el.querySelector("img");
    if (img?.complete && img.naturalWidth > 0) setSharp(true);
    // load does not bubble, but a capture listener on the box still hears it
    const on = () => setSharp(true);
    el.addEventListener("load", on, true);
    return () => el.removeEventListener("load", on, true);
  }, [photo]);

  return (
    <article
      data-testid="premium-member-card"
      className={`flex flex-col overflow-hidden rounded-xl bg-card ${className}`}
      style={style}
    >
      <div className="relative">
        <ProfileLink userId={m.user_id} handle={m.handle} aria-label={`${m.full_name} — profile`} className="block">
          <div ref={box} className="relative aspect-[4/5] w-full overflow-hidden bg-muted">
            {blur && (
              <span aria-hidden="true" data-testid="premium-blur" className="absolute inset-0 bg-cover bg-center" style={{ backgroundImage: `url(${blur})` }} />
            )}
            {photo && (
              <OptimizedImage
                src={photo}
                alt={`Photograph by ${m.full_name}`}
                loading="lazy"
                className={`relative h-full w-full object-cover transition-opacity duration-300 ${sharp ? "opacity-100" : "opacity-0"}`}
              />
            )}
          </div>
        </ProfileLink>
        {/* the shared avatar (PresenceAvatar: photo, else initial); no online dot on this card */}
        <span className="absolute left-2.5 rounded-full bg-card p-0.5" style={AVATAR_POS} aria-hidden="true">
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
            <UserBadgeInline badges={VERIFIED} only="verified" userId={m.user_id} name={m.full_name} />
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

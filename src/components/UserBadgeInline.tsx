import LazyBadgeTrigger from "@/components/badges/LazyBadgeTrigger";
import VerifiedTick from "@/components/VerifiedTick";
import { useBadgeDefinitions } from "@/hooks/profile/useBadgeDefinitions";
import { solidPillClass, BADGE_ICON_SIZE, BADGE_ROW_SHRINK } from "@/lib/badgePalette";

interface Props {
  badges: string[];
  size?: "compact" | "full";
  /**
   * Render only part of the set.
   *
   * The blue verified tick and the coloured award pills behave differently when
   * space is tight: the tick is a fixed 14px glyph that always fits and belongs
   * immediately after the name (that is what the tick MEANS — this name is the
   * real person), while a pill is a word that needs room. `only` lets a narrow
   * layout keep the tick on the name's line and move the pills below.
   *
   * Default "all" — every existing caller keeps today's single-row behaviour.
   */
  only?: "all" | "verified" | "pills";
  /**
   * Whose badges these are. With it, the blue tick opens the Verified
   * Photographer card (VerifiedTick) naming this member; without it the tick
   * is drawn plain. Every name-rendering caller passes it.
   */
  userId?: string | null;
  /** The member's name, when the caller has it — saves the card a lookup. */
  name?: string | null;
}

const UserBadgeInline = ({ badges, size = "compact", only = "all", userId, name }: Props) => {
  const defs = useBadgeDefinitions();

  if (!badges || badges.length === 0) return null;

  // ONE tick: gold Elite Member over blue Verified (the latest wins — SQL 7000 removes the gold when blue
  // is given later). A switched-off Elite badge type (definitions loaded, without it) falls back to blue.
  const isElite = badges.includes("elite_member") && (defs.size === 0 || defs.has("elite_member"));
  const hasTick = (isElite || badges.includes("verified")) && only !== "pills";
  const otherBadges = only === "verified" ? [] : badges.filter((b) => b !== "verified" && b !== "elite_member");

  // Nothing left to draw for this half — render nothing rather than an empty
  // inline box, which would still take the row's gap.
  if (!hasTick && otherBadges.length === 0) return null;

  // Size + colour now come from ONE place (src/lib/badgePalette.ts) and the
  // stored class string is normalised there, so a badge cannot render
  // unreadable whatever the database holds. Was: 7px text on a 15%-transparent
  // fill, which failed WCAG AA in both modes for all ten colours.
  const tickSize = size === "compact" ? "h-3.5 w-3.5" : "h-4 w-4";

  // The tick is its OWN box that never shrinks (28 Nov 2026: a long name — "Ranjana Bhattacharya Chowdhury" — took
  // the whole row and the tick, inside the shrinking pill row, was clipped to nothing). Only the award pills, which
  // are words, give way to the name; the tick always shows next to it.
  const tick = hasTick ? (
    <span className="inline-flex shrink-0 items-center align-middle">
      <VerifiedTick userId={userId} name={name} className={tickSize} gold={isElite} />
    </span>
  ) : null;
  if (otherBadges.length === 0) return tick;

  return (
    <>
    {tick}
    <span className={`inline-flex items-center gap-1 align-middle ${BADGE_ROW_SHRINK}`}>
      {otherBadges.map((b) => {
        const cfg = defs.get(b);
        if (!cfg) return null;
        return (
          <LazyBadgeTrigger key={b} badge={b} userId={userId} name={name} label={cfg.label} className={solidPillClass(cfg.badge_class, size)}>
            <span className={BADGE_ICON_SIZE}>{cfg.icon}</span>
            {cfg.show_label !== false && <span className="truncate">{cfg.label}</span>}
          </LazyBadgeTrigger>
        );
      })}
    </span>
    </>
  );
};

export default UserBadgeInline;

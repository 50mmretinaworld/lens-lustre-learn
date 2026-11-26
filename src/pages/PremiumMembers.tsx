import PageSEO from "@/components/PageSEO";
import VerifiedBadge from "@/components/VerifiedBadge";
import PremiumMemberCard from "@/components/premium/PremiumMemberCard";
import { usePremiumFollow } from "@/components/premium/usePremiumFollow";
import { usePremiumMembers } from "@/hooks/feed/usePremiumMembers";

/**
 * /premium-members — THE PREMIUM MEMBERS PAGE (Owner-approved plan, Part 4).
 *
 * App / phone first: two cards per row at phone width, more when wider. Works
 * signed out (the server function is callable by anyone). Every sentence on
 * this page was approved by the Owner word for word — change none of them
 * without a new yes. The grid uses the ONE PremiumMemberCard the feed row uses.
 */

const headingFont = { fontFamily: "var(--font-heading)" };
const displayFont = { fontFamily: "var(--font-display)" };
const bodyFont = { fontFamily: "var(--font-body)" };

const BLOCKS: ReadonlyArray<[string, string]> = [
  ["Their own work", "Every honoured photographer posts original photographs they made themselves."],
  ["Chosen by people", "Our curators look at the work and the conduct. No formula, no follower count."],
  ["Never for sale", "The tick cannot be bought or requested. It can be taken away if the trust is broken."],
];

const FAQ: ReadonlyArray<[string, string]> = [
  ["How do I become Verified?", "You can't apply. Keep sharing your own best work and taking part with respect. Our curators notice."],
  ["Can I pay for the tick?", "No. Not now, not later."],
  ["Can the tick be removed?", "Yes, if a member posts work that isn't their own or breaks the community rules."],
];

export default function PremiumMembers() {
  const { data: members = [], isLoading } = usePremiumMembers();
  const { isFollowing, follow, join, busyId, prompt, selfId, signedIn } = usePremiumFollow(members);
  const n = members.length;

  return (
    <main className="min-h-screen bg-background text-foreground" data-testid="premium-members-page">
      <PageSEO
        title="Premium Members"
        description="Each photographer here was chosen by the 50mm Retina World curators for original work and good conduct in our community. Nobody can apply for this tick, and nobody can buy it."
      />
      <div className="mx-auto w-full max-w-5xl px-4 pb-12 pt-5 md:pt-12">
        <header className="flex flex-col gap-3 md:max-w-2xl">
          <p className="flex items-center gap-1.5 text-[13px] font-semibold text-primary" style={headingFont}>
            <VerifiedBadge className="h-5 w-5 shrink-0" aria-hidden="true" />
            Premium Members · Verified Photographers
          </p>
          <h1 className="text-[28px] font-light leading-tight tracking-tight md:text-5xl" style={displayFont}>
            Honoured by our curators. <span className="text-primary">Never requested. Never sold.</span>
          </h1>
          <p className="text-[15px] leading-relaxed text-foreground/80" style={bodyFont}>
            Each photographer here was chosen by the 50mm Retina World curators for original work and good conduct in our community. Nobody can apply for this tick, and nobody can buy it.
          </p>
          <ul className="flex flex-wrap gap-2" style={headingFont}>
            {n > 0 && (
              <li className="rounded-full border border-border px-3 py-1.5 text-[13px] font-semibold" data-testid="premium-count">
                {n} photographers honoured
              </li>
            )}
            <li className="rounded-full border border-border px-3 py-1.5 text-[13px] font-semibold">₹0 paid by anyone, ever</li>
          </ul>
          {!signedIn && (
            <button
              type="button"
              onClick={join}
              className="mt-1 inline-flex h-11 w-full items-center justify-center rounded-lg bg-primary px-5 text-[15px] font-semibold text-primary-foreground hover:opacity-90 sm:w-auto sm:self-start"
              style={headingFont}
            >
              Join free
            </button>
          )}
        </header>

        {isLoading ? (
          <div className="mt-6 grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-4" aria-hidden="true">
            {[0, 1, 2, 3].map((i) => <div key={i} className="aspect-[4/7] animate-pulse rounded-xl bg-muted" />)}
          </div>
        ) : n > 0 ? (
          <section aria-label="Premium Members" className="mt-6 grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-4">
            {members.map((m) => (
              <PremiumMemberCard
                key={m.user_id}
                member={m}
                following={isFollowing(m.user_id)}
                self={m.user_id === selfId}
                busy={busyId === m.user_id}
                onFollow={follow}
              />
            ))}
          </section>
        ) : null}

        <section aria-label="About the tick" className="mt-10 grid gap-3 md:grid-cols-3">
          {BLOCKS.map(([title, text]) => (
            <div key={title} className="rounded-xl bg-card p-4">
              <h2 className="text-[15px] font-bold" style={headingFont}>{title}</h2>
              <p className="mt-1 text-sm leading-relaxed text-foreground/80" style={bodyFont}>{text}</p>
            </div>
          ))}
        </section>

        <section aria-label="Questions" className="mt-10 md:max-w-2xl">
          <dl className="flex flex-col divide-y divide-border">
            {FAQ.map(([q, a]) => (
              <div key={q} className="py-4">
                <dt className="text-[15px] font-semibold" style={headingFont}>{q}</dt>
                <dd className="mt-1 text-sm leading-relaxed text-foreground/80" style={bodyFont}>{a}</dd>
              </div>
            ))}
          </dl>
        </section>
      </div>
      {prompt}
    </main>
  );
}

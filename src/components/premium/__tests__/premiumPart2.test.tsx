/**
 * Premium Members Part 2 — the focused checks:
 *   • the tick card says the Owner-approved words VERBATIM (date clause only when known)
 *   • tapping the tick opens the card and does NOT follow a link around the name;
 *     the brand/admin account keeps its tooltip
 *   • the Featured post sorts first and its tile carries "★ Featured"
 *   • "Set as Featured photo" only on the viewer's own public photo, only for a Verified member
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import type { ReactNode } from "react";
import type { UnifiedPost } from "@/types/post";

const honour = { data: null as null | { assignedAt: string | null }, isLoading: false };
const featured = { data: null as string | null, isLoading: false };
const mutate = vi.fn();
let admins = new Set<string>();

vi.mock("@/hooks/profile/usePremiumHonour", () => ({
  useVerifiedHonour: () => honour,
  useFeaturedPostId: () => featured,
  useMarkFeaturedPost: () => ({ mutate, isPending: false }),
}));
vi.mock("@/hooks/profile/useMemberName", () => ({
  useMemberName: (_id: string, name: string | null | undefined) => name ?? "Tanmay De",
}));
vi.mock("@/hooks/core/useAdminIds", () => ({ useAdminIds: () => admins }));
vi.mock("@/components/ui/tooltip", () => ({
  Tooltip: ({ children }: { children: ReactNode }) => <>{children}</>,
  TooltipTrigger: ({ children }: { children: ReactNode }) => <>{children}</>,
  TooltipContent: ({ children }: { children: ReactNode }) => <span data-testid="tooltip">{children}</span>,
}));
vi.mock("@/components/ui/dropdown-menu", () => ({
  DropdownMenuItem: ({ children, onClick, ...rest }: { children: ReactNode; onClick?: () => void }) => (
    <button type="button" onClick={onClick} {...rest}>{children}</button>
  ),
}));
vi.mock("@/hooks/core/usePhotoSetV2", () => ({ usePhotoSetV2: () => false }));
vi.mock("@/components/feed/FeedCardWindow", () => ({ default: ({ children }: { children: ReactNode }) => <div>{children}</div> }));
vi.mock("@/components/video/VideoPoster", () => ({ default: () => <span /> }));

import { verifiedTickMessage, VERIFIED_CARD_TITLE, VERIFIED_CARD_LINK_TEXT } from "@/lib/premium/premiumMember";
import { featuredFirst, canOfferFeatured } from "@/lib/premium/featuredRead";
import VerifiedTick, { BRAND_TICK_TOOLTIP } from "@/components/VerifiedTick";
import VerifiedTickCard from "@/components/premium/VerifiedTickCard";
import FeaturedPhotoMenuItem, { SET_FEATURED_TEXT, REMOVE_FEATURED_TEXT } from "@/components/premium/FeaturedPhotoMenuItem";
import ProfilePostGrid from "@/components/profile/ProfilePostGrid";
import { honourAddress, honourFileName, HONOUR_LINE, HONOUR_SIZES } from "@/lib/premium/honourImage";

beforeEach(() => {
  honour.data = null;
  featured.data = null;
  mutate.mockReset();
  admins = new Set();
});

describe("tick card wording (Owner-approved, verbatim)", () => {
  it("names the member and the month", () => {
    expect(VERIFIED_CARD_TITLE).toBe("Verified Photographer");
    expect(VERIFIED_CARD_LINK_TEXT).toBe("See all Verified Photographers");
    expect(verifiedTickMessage("Tanmay De", "2026-03-14T10:00:00Z")).toBe(
      "Tanmay De was honoured by the 50mm Retina World curators in Mar 2026. This tick cannot be requested or bought.",
    );
  });

  it("leaves the date clause out when the date is unknown", () => {
    expect(verifiedTickMessage("Neil Basu", null)).toBe(
      "Neil Basu was honoured by the 50mm Retina World curators. This tick cannot be requested or bought.",
    );
  });

  it("the card renders title, sentence and the link to /premium-members", () => {
    honour.data = { assignedAt: "2026-11-02T00:00:00Z" };
    const trigger = { current: null };
    render(
      <MemoryRouter>
        <VerifiedTickCard userId="u1" name="Dr. Subhamay Karmakar" anchor={{ left: 10, top: 10, width: 14, height: 14, right: 24, bottom: 24 } as DOMRect} trigger={trigger} onClose={() => {}} />
      </MemoryRouter>,
    );
    const card = screen.getByTestId("verified-tick-card");
    expect(within(card).getByText("Verified Photographer")).toBeTruthy();
    expect(within(card).getByText(
      "Dr. Subhamay Karmakar was honoured by the 50mm Retina World curators in Nov 2026. This tick cannot be requested or bought.",
    )).toBeTruthy();
    expect(within(card).getByRole("link", { name: "See all Verified Photographers" }).getAttribute("href")).toBe("/premium-members");
    expect(card.textContent).not.toContain("Authenticated identity");
  });
});

describe("the tick inside a name link", () => {
  it("opens the card and does not follow the link around it", async () => {
    honour.data = { assignedAt: null };
    const followed = vi.fn();
    render(
      <MemoryRouter>
        <a href="/someone" onClick={followed}>
          Tanmay De <VerifiedTick userId="u1" name="Tanmay De" />
        </a>
      </MemoryRouter>,
    );
    fireEvent.click(screen.getByRole("button", { name: "Verified Photographer" }));
    expect(followed).not.toHaveBeenCalled();
    const card = await screen.findByTestId("verified-tick-card");
    fireEvent.click(within(card).getByText(/was honoured/));
    expect(followed).not.toHaveBeenCalled();
  });

  it("the 50mm brand/admin account keeps its old tooltip and opens no card", () => {
    admins = new Set(["brand"]);
    render(<VerifiedTick userId="brand" name="50mm Retina World" />);
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.getByTestId("tooltip").textContent).toBe(BRAND_TICK_TOOLTIP);
  });
});

const post = (id: string, extra: Partial<UnifiedPost> = {}): UnifiedPost =>
  ({ id, user_id: "m1", privacy: "public", image_urls: [`https://cdn.example/${id}.jpg`], thumbnail_urls: [], content: id, created_at: "2026-11-01", reaction_counts: {}, comment_count: 0, ...extra }) as unknown as UnifiedPost;

describe("Featured photo first", () => {
  it("moves the Featured post to the front, else prepends the one fetched on its own", () => {
    const ps = [post("a"), post("b"), post("c")];
    expect(featuredFirst(ps, "c").map((p) => p.id)).toEqual(["c", "a", "b"]);
    expect(featuredFirst(ps, "a")).toBe(ps);
    expect(featuredFirst(ps, null)).toBe(ps);
    expect(featuredFirst(ps, "z", post("z")).map((p) => p.id)).toEqual(["z", "a", "b", "c"]);
    expect(featuredFirst(ps, "z", null).map((p) => p.id)).toEqual(["a", "b", "c"]);
  });

  it("the first grid tile carries the ★ Featured label, and only that one", () => {
    const ps = featuredFirst([post("a"), post("b"), post("c")], "b");
    const { container } = render(
      <MemoryRouter>
        <ProfilePostGrid posts={ps} featuredPostId="b" />
      </MemoryRouter>,
    );
    const labels = screen.getAllByText("★ Featured");
    expect(labels).toHaveLength(1);
    const tiles = container.querySelectorAll("a");
    expect(tiles[0].contains(labels[0])).toBe(true);
    expect(tiles[0].getAttribute("aria-label")).toMatch(/^Featured\. /);
    expect(tiles[1].getAttribute("aria-label")).not.toMatch(/^Featured/);
  });
});

describe("Share my honour image text", () => {
  it("prints the member's address, or just the site when there is no handle; two sizes", () => {
    expect(honourAddress("neil.basu")).toBe("50mmretina.com/neil.basu");
    expect(honourAddress("@neil.basu")).toBe("50mmretina.com/neil.basu");
    expect(honourAddress(null)).toBe("50mmretina.com");
    expect(HONOUR_LINE).toBe("Honoured as Premium Member");
    expect(HONOUR_SIZES.post).toMatchObject({ width: 1080, height: 1350 });
    expect(HONOUR_SIZES.story).toMatchObject({ width: 1080, height: 1920 });
    expect(honourFileName("neil.basu", "story")).toBe("50mm-premium-member-neil.basu-story.jpg");
  });
});

describe("⋯ menu: Set / Remove Featured photo", () => {
  it("is offered only on the viewer's own public photo post", () => {
    expect(canOfferFeatured(post("a"), "m1", false)).toBe(true);
    expect(canOfferFeatured(post("a"), "someone-else", false)).toBe(false);
    expect(canOfferFeatured(post("a"), undefined, false)).toBe(false);
    expect(canOfferFeatured(post("a", { privacy: "friends" }), "m1", false)).toBe(false);
    expect(canOfferFeatured(post("a", { image_urls: [] }), "m1", false)).toBe(false);
    expect(canOfferFeatured(post("a"), "m1", true)).toBe(false);
  });

  it("draws nothing for a member without the Verified honour", () => {
    honour.data = null;
    const { container } = render(<FeaturedPhotoMenuItem userId="m1" postId="a" />);
    expect(container.textContent).toBe("");
  });

  it("a Verified member gets the gold Set line; marking calls set_featured_post with the post", () => {
    honour.data = { assignedAt: null };
    featured.data = "other";
    render(<FeaturedPhotoMenuItem userId="m1" postId="a" />);
    fireEvent.click(screen.getByText(SET_FEATURED_TEXT));
    expect(mutate).toHaveBeenCalledWith("a");
  });

  it("on the current Featured post the line is Remove, which unmarks (null)", () => {
    honour.data = { assignedAt: null };
    featured.data = "a";
    render(<FeaturedPhotoMenuItem userId="m1" postId="a" />);
    fireEvent.click(screen.getByText(REMOVE_FEATURED_TEXT));
    expect(mutate).toHaveBeenCalledWith(null);
  });
});

/**
 * The feed row "Meet our Premium Members" never shows the viewer their own card
 * (Owner 27 Nov 2026). Signed out, everyone is shown.
 */
import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

const h = vi.hoisted(() => ({ members: [] as { user_id: string }[], selfId: null as string | null }));

vi.mock("@/hooks/feed/usePremiumMembers", () => ({ usePremiumMembers: () => ({ data: h.members }) }));
vi.mock("@/components/premium/usePremiumFollow", () => ({
  usePremiumFollow: () => ({ isFollowing: () => false, follow: () => {}, busyId: null, prompt: null, selfId: h.selfId }),
}));
vi.mock("@/components/premium/PremiumMemberCard", () => ({
  default: ({ member }: { member: { user_id: string } }) => <span data-testid="card">{member.user_id}</span>,
}));
vi.mock("@/components/VerifiedBadge", () => ({ default: () => null }));

import FeedPremiumMembers from "@/components/feed/FeedPremiumMembers";

const shown = () => screen.queryAllByTestId("card").map((c) => c.textContent);
const draw = () => render(<MemoryRouter><FeedPremiumMembers /></MemoryRouter>);

describe("FeedPremiumMembers — own card", () => {
  beforeEach(() => {
    cleanup();
    vi.stubGlobal("ResizeObserver", class { observe() {} disconnect() {} });
    h.members = [{ user_id: "me" }, { user_id: "other" }];
  });

  it("leaves the viewer out", () => {
    h.selfId = "me";
    draw();
    expect(shown()).toEqual(["other"]);
  });

  it("signed out: everyone", () => {
    h.selfId = null;
    draw();
    expect(shown()).toEqual(["me", "other"]);
  });

  it("no row at all when the viewer is the only one", () => {
    h.selfId = "me";
    h.members = [{ user_id: "me" }];
    draw();
    expect(screen.queryByTestId("feed-premium-members")).toBeNull();
  });
});

/**
 * Badge / role popups written by Admin and the gold Elite Member tick (Owner 27 Nov 2026, SQL 7000).
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, within, cleanup } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import type { ReactNode } from "react";

const h = vi.hoisted(() => ({ badges: new Map<string, unknown>(), roles: new Map<string, unknown>() }));

vi.mock("@/hooks/profile/useBadgeDefinitions", () => ({ useBadgeDefinitions: () => h.badges }));
vi.mock("@/hooks/profile/useRoleDefinitions", () => ({ useRoleDefinitions: () => h.roles }));
vi.mock("@/hooks/profile/useMemberName", () => ({ useMemberName: (_id: string, name?: string | null) => name ?? "Tanmay De" }));
vi.mock("@/hooks/profile/useBadgeMonth", () => ({ useBadgeMonth: () => ({ data: "2026-11-02T00:00:00Z", isLoading: false }) }));
vi.mock("@/hooks/profile/usePremiumHonour", () => ({ useVerifiedHonour: () => ({ data: { assignedAt: "2026-03-01T00:00:00Z" }, isLoading: false }) }));
vi.mock("@/hooks/core/useAdminIds", () => ({ useAdminIds: () => new Set<string>() }));
vi.mock("@/components/ui/tooltip", () => ({
  Tooltip: ({ children }: { children: ReactNode }) => <>{children}</>,
  TooltipTrigger: ({ children }: { children: ReactNode }) => <>{children}</>,
  TooltipContent: () => null,
}));

import UserBadgeInline from "@/components/UserBadgeInline";
import UserRoleInline from "@/components/UserRoleInline";
import { fillPopupText } from "@/lib/badges/badgeText";

const def = (label: string, more: Record<string, unknown> = {}) => ({ label, icon: "🚀", badge_class: "bg-violet-600", pill_class: "bg-violet-600", show_inline: true, ...more });
const draw = (ui: ReactNode) => render(<MemoryRouter>{ui}</MemoryRouter>);
/** The popup code is lazy: wait until the badge has become a button. */
const badge = (name: string) => screen.findByRole("button", { name }, { timeout: 5000 });

beforeEach(() => {
  cleanup();
  h.badges = new Map<string, unknown>([["rising_star", def("Rising Star")], ["elite_member", def("Elite Member")]]);
  h.roles = new Map<string, unknown>([["judge", def("Judge")]]);
});

describe("the words", () => {
  it("fills name and month; leaves 'in {month}' out when unknown", () => {
    expect(fillPopupText("{name} joined in {month}.", "Neil", "Nov 2026")).toBe("Neil joined in Nov 2026.");
    expect(fillPopupText("{name} joined in {month}.", "Neil", null)).toBe("Neil joined.");
  });
});

describe("a badge", () => {
  it("shows its name by default and opens Admin's heading and message", async () => {
    h.badges.set("rising_star", def("Rising Star", { popup_title: "New talent", popup_message: "{name} is rising since {month}." }));
    draw(<UserBadgeInline badges={["rising_star"]} userId="u1" name="Neil Basu" />);
    expect(screen.getByText("Rising Star")).toBeTruthy();
    fireEvent.click(await badge("Rising Star"));
    const card = screen.getByTestId("verified-tick-card");
    expect(within(card).getByText("New talent")).toBeTruthy();
    expect(within(card).getByText("Neil Basu is rising since Nov 2026.")).toBeTruthy();
  });

  it("name switched off: only the icon", async () => {
    h.badges.set("rising_star", def("Rising Star", { show_label: false }));
    draw(<UserBadgeInline badges={["rising_star"]} userId="u1" name="Neil Basu" />);
    expect(screen.queryByText("Rising Star")).toBeNull();
    expect(screen.getByText("🚀")).toBeTruthy();
    fireEvent.click(await badge("Rising Star"));
    expect(within(screen.getByTestId("verified-tick-card")).getByText("Rapidly gaining recognition")).toBeTruthy();
  });

  it("opens on mouse over", async () => {
    draw(<UserBadgeInline badges={["rising_star"]} userId="u1" name="Neil Basu" />);
    // React builds enter / leave from pointerover; jsdom has no PointerEvent, so the type is set by hand.
    const over = new MouseEvent("pointerover", { bubbles: true });
    Object.defineProperty(over, "pointerType", { value: "mouse" });
    fireEvent(await badge("Rising Star"), over);
    expect(screen.getByTestId("verified-tick-card")).toBeTruthy();
  });

  it("a role works the same way", async () => {
    h.roles.set("judge", def("Judge", { popup_message: "{name} sits on the jury." }));
    draw(<UserRoleInline roles={["judge"]} userId="u1" />);
    fireEvent.click(await badge("Judge"));
    expect(within(screen.getByTestId("verified-tick-card")).getByText("Tanmay De sits on the jury.")).toBeTruthy();
  });
});

describe("one tick: gold over blue", () => {
  it("blue and gold → one gold tick, no blue, no pill", async () => {
    draw(<UserBadgeInline badges={["verified", "elite_member"]} userId="u1" name="Neil Basu" />);
    fireEvent.click(await badge("Elite Member"));
    expect(screen.queryByRole("button", { name: "Verified Photographer" })).toBeNull();
    const card = screen.getByTestId("verified-tick-card");
    expect(within(card).getByText("Neil Basu is an Elite Member of 50mm Retina World.")).toBeTruthy();
    expect(within(card).queryByRole("link")).toBeNull();
  });

  it("blue alone keeps the approved words", async () => {
    draw(<UserBadgeInline badges={["verified"]} userId="u1" name="Neil Basu" />);
    fireEvent.click(await badge("Verified Photographer"));
    expect(within(screen.getByTestId("verified-tick-card")).getByText(
      "Neil Basu was honoured by the 50mm Retina World curators in Mar 2026. This tick cannot be requested or bought.",
    )).toBeTruthy();
  });

  it("Elite badge type switched off → blue again", async () => {
    h.badges.delete("elite_member");
    draw(<UserBadgeInline badges={["verified", "elite_member"]} userId="u1" name="Neil Basu" />);
    expect(await badge("Verified Photographer")).toBeTruthy();
  });
});

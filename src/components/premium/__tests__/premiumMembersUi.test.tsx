/**
 * PREMIUM MEMBERS — the card, the signed-out Join prompt and the remembered
 * follow (Owner-approved plan, 26 Nov 2026, Parts 3, 4, 4b).
 */
import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

const h = vi.hoisted(() => ({ mutate: vi.fn(), invalidate: vi.fn() }));

vi.mock("@/components/ProfileLink", () => ({
  default: ({ children, className, "aria-label": al }: { children: React.ReactNode; className?: string; "aria-label"?: string }) =>
    <a href="/neil.basu" className={className} aria-label={al}>{children}</a>,
}));
vi.mock("@/components/UserBadgeInline", () => ({ default: () => <span data-testid="tick">tick</span> }));
vi.mock("@/components/PresenceAvatar", () => ({ default: () => <span data-testid="avatar" /> }));
vi.mock("@/components/OptimizedImage", () => ({ default: ({ alt }: { alt: string }) => <span role="img" aria-label={alt} /> }));
vi.mock("@/hooks/social/useFriendshipMutations", () => ({ useToggleFollow: () => ({ mutate: h.mutate }) }));
vi.mock("@/lib/native/authDeepLink", () => ({ isNativeCapacitorApp: () => false }));

const { default: PremiumMemberCard } = await import("@/components/premium/PremiumMemberCard");
const { default: GuestFollowPrompt } = await import("@/components/premium/GuestFollowPrompt");
const { default: PendingFollowRunner } = await import("@/components/premium/PendingFollowRunner");
const { savePendingFollow, readPendingFollow, PENDING_FOLLOW_KEY } = await import("@/lib/social/pendingFollow");
const { APP_STORE_URL, PLAY_STORE_URL, joinViaAppUrl } = await import("@/lib/native/appLinks");
const { honouredLabel } = await import("@/lib/premium/premiumMember");
import type { PremiumMember } from "@/hooks/feed/usePremiumMembers";

const member = (over: Partial<PremiumMember> = {}): PremiumMember => ({
  user_id: "u1", full_name: "Neil Basu", handle: "neil.basu", avatar_url: null, post_id: "p1",
  photo_url: "https://cdn.example/x.jpg", thumb_url: null, is_featured: true, line: null,
  line_is_citation: false, honoured_at: "2026-11-20T10:00:00Z", ...over,
});

const ANDROID = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/131 Mobile Safari/537.36";
const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 Version/18.1 Mobile/15E148 Safari/604.1";
const DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36";

const inRouter = (ui: React.ReactNode) => {
  const qc = new QueryClient();
  qc.invalidateQueries = h.invalidate as unknown as QueryClient["invalidateQueries"];
  return render(<QueryClientProvider client={qc}><MemoryRouter>{ui}</MemoryRouter></QueryClientProvider>);
};

beforeEach(() => { cleanup(); h.mutate.mockReset(); localStorage.clear(); });

describe("PremiumMemberCard — the line", () => {
  it("a curator's citation is italic", () => {
    inRouter(<PremiumMemberCard member={member({ line: "Honoured for a steady eye.", line_is_citation: true })} following={false} onFollow={() => {}} />);
    const line = screen.getByTestId("premium-line");
    expect(line.textContent).toBe("Honoured for a steady eye.");
    expect(line.className).toMatch(/\bitalic\b/);
    expect(line.className).toMatch(/line-clamp-2/);
  });

  it("a line from the member's bio is plain", () => {
    inRouter(<PremiumMemberCard member={member({ line: "Street photographer, Kolkata", line_is_citation: false })} following={false} onFollow={() => {}} />);
    expect(screen.getByTestId("premium-line").className).not.toMatch(/\bitalic\b/);
  });

  it("no line → nothing at all", () => {
    inRouter(<PremiumMemberCard member={member({ line: null })} following={false} onFollow={() => {}} />);
    expect(screen.queryByTestId("premium-line")).toBeNull();
  });

  it("shows name, tick, 'Honoured Nov 2026' and Follow / Following — no follower count", () => {
    const onFollow = vi.fn();
    inRouter(<PremiumMemberCard member={member()} following={false} onFollow={onFollow} />);
    expect(screen.getByText("Neil Basu")).toBeTruthy();
    expect(screen.getByTestId("tick")).toBeTruthy();
    expect(screen.getByText("Honoured Nov 2026")).toBeTruthy();
    const btn = screen.getByRole("button", { name: "Follow Neil Basu" });
    btn.click();
    expect(onFollow).toHaveBeenCalledWith(expect.objectContaining({ user_id: "u1" }));
    cleanup();
    inRouter(<PremiumMemberCard member={member()} following onFollow={() => {}} />);
    expect(screen.getByRole("button", { name: "Following Neil Basu" }).getAttribute("aria-pressed")).toBe("true");
    expect(document.body.textContent).not.toMatch(/follower/i);
  });

  it("no Follow button on the viewer's own card", () => {
    inRouter(<PremiumMemberCard member={member()} following={false} self onFollow={() => {}} />);
    expect(screen.queryByRole("button")).toBeNull();
  });

  it("honouredLabel is the UTC month and year, null for a missing date", () => {
    expect(honouredLabel("2026-09-01T00:30:00Z")).toBe("Sep 2026");
    expect(honouredLabel(null)).toBeNull();
    expect(honouredLabel("not a date")).toBeNull();
  });
});

describe("GuestFollowPrompt — a signed-out visitor taps Follow", () => {
  it("Android phone: 'Join via App' is the intent link to that profile, Play Store as fallback", () => {
    inRouter(<GuestFollowPrompt member={member()} onClose={() => {}} ua={ANDROID} touchPoints={5} />);
    expect(screen.getByTestId("guest-follow-sheet")).toBeTruthy();
    const href = screen.getByTestId("join-via-app").getAttribute("href")!;
    expect(href).toMatch(/^intent:\/\/[^/]*\/neil\.basu#Intent;scheme=https;package=com\.fiftymmretina\.app;/);
    expect(href).toContain(`S.browser_fallback_url=${encodeURIComponent(PLAY_STORE_URL)}`);
    expect(screen.getByText("Follow Neil Basu")).toBeTruthy();
    expect(screen.getByText("Join 50mm Retina World free to follow Premium Members.")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Continue on website" }).getAttribute("href")).toBe("/signup");
    expect(screen.getByRole("link", { name: "Sign in" }).getAttribute("href")).toBe("/login");
  });

  it("iPhone: 'Join via App' opens the App Store", () => {
    inRouter(<GuestFollowPrompt member={member()} onClose={() => {}} ua={IPHONE} touchPoints={5} />);
    expect(screen.getByTestId("join-via-app").getAttribute("href")).toBe(APP_STORE_URL);
    expect(APP_STORE_URL).toBe("https://apps.apple.com/app/id6809751061");
  });

  it("iPad (Safari says Macintosh + touch) is an iPhone/iPad device too", () => {
    expect(joinViaAppUrl("/x", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15", 5)).toBe(APP_STORE_URL);
  });

  it("computer: a centred dialog with Join free, Sign in and both store links", () => {
    inRouter(<GuestFollowPrompt member={member()} onClose={() => {}} ua={DESKTOP} touchPoints={0} />);
    expect(screen.getByTestId("guest-follow-dialog")).toBeTruthy();
    expect(screen.queryByTestId("join-via-app")).toBeNull();
    expect(screen.getByRole("link", { name: "Join free" }).getAttribute("href")).toBe("/signup");
    expect(screen.getByRole("link", { name: "Sign in" }).getAttribute("href")).toBe("/login");
    expect(screen.getByRole("link", { name: "Google Play" }).getAttribute("href")).toBe(PLAY_STORE_URL);
    expect(screen.getByRole("link", { name: "App Store" }).getAttribute("href")).toBe(APP_STORE_URL);
  });
});

describe("the remembered follow is done ONCE after sign-in", () => {
  it("follows with the 'You're now following' toast, clears it, and never repeats", () => {
    savePendingFollow({ id: "u1", name: "Neil Basu" });
    const view = inRouter(<PendingFollowRunner userId="me" />);
    expect(h.mutate).toHaveBeenCalledTimes(1);
    expect(h.mutate.mock.calls[0][0]).toEqual({ targetUserId: "u1", isCurrentlyFollowing: false, successTitle: "You're now following Neil Basu" });
    expect(readPendingFollow()).toBeNull();
    expect(localStorage.getItem(PENDING_FOLLOW_KEY)).toBeNull();
    view.rerender(<QueryClientProvider client={new QueryClient()}><MemoryRouter><PendingFollowRunner userId="me" /></MemoryRouter></QueryClientProvider>);
    cleanup();
    inRouter(<PendingFollowRunner userId="me" />);
    expect(h.mutate).toHaveBeenCalledTimes(1);
  });

  it("never follows yourself", () => {
    savePendingFollow({ id: "me", name: "Me" });
    inRouter(<PendingFollowRunner userId="me" />);
    expect(h.mutate).not.toHaveBeenCalled();
    expect(readPendingFollow()).toBeNull();
  });

  it("storage that throws is simply 'nothing remembered'", () => {
    const spy = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => { throw new Error("blocked"); });
    expect(readPendingFollow()).toBeNull();
    spy.mockRestore();
  });
});

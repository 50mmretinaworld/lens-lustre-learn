import { describe, it, expect } from "vitest";
import { opensOnEveryApp, safeAppLink, TAP_PAGES_EVERY_APP } from "@/lib/notifications/broadcastTap";
import { legacyTapTarget, safeLink, LEGACY_TAP_PAGES } from "../../supabase/functions/_shared/broadcastMessage";
import { getNotifLink } from "@/lib/notificationLinks";

/**
 * The site/app copy of the tap rule and the sender's copy must say the same
 * thing — and both must agree with the table old app builds really use
 * (getNotifLink). If the admin page says "opens on every app" and the sender
 * maps it differently, the Owner's 16 Nov bug comes back silently.
 */
const SAMPLES = [
  "/", "/feed", "/feed?compose=1", "/post/abc", "/post", "/post/abc/extra",
  "/competitions", "/competitions/monsoon-moods", "/competitions/monsoon-moods/submit",
  "/journal", "/journal/a-story", "/courses", "/courses/light-101", "/courses/light-101/lessons/2",
  "/friends", "/friends/requests", "/certificates", "/discover", "/help-support", "/wallet", "/dashboard",
  "/dashboard/x", "/notifications", "/settings", "/some_member", "/competion",
  "", "feed", "//evil.example", "https://evil.example/x", "javascript:alert(1)", "/a b",
];

describe("one tap rule — site/app copy == sender copy == the old app's own table", () => {
  it("the page lists are identical", () => {
    expect([...TAP_PAGES_EVERY_APP]).toEqual([...LEGACY_TAP_PAGES]);
  });

  it.each(SAMPLES)("safe-link check agrees for %j", (link) => {
    expect(safeAppLink(link)).toBe(safeLink(link));
  });

  it.each(SAMPLES)("'opens on every app' is true exactly when an old build lands on that page: %j", (link) => {
    const t = legacyTapTarget(link);
    const oldBuildLandsOn = getNotifLink({ type: t.type, reference_id: t.reference_id ?? null });
    const wanted = (safeLink(link) ?? "").split(/[?#]/)[0];
    expect(opensOnEveryApp(link)).toBe(!!safeLink(link) && oldBuildLandsOn === wanted);
  });

  it("the Owner's case: /competitions opens; a misspelt address does not", () => {
    expect(opensOnEveryApp("/competitions")).toBe(true);
    expect(opensOnEveryApp("/competion")).toBe(false);
  });
});

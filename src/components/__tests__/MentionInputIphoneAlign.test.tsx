/**
 * Owner, 25 Nov 2026 (iPhone): typing "goes to the left" in every comment box (new, reply, edit).
 *
 * react-mentions draws the letters in a highlighter and keeps a TRANSPARENT textarea on top for the caret.
 * On an iPhone/iPad user agent the library adds `marginTop: 1, marginLeft: -3` to that textarea (an old-iOS
 * hack). Measured in WebKit: caret layer x=49 vs letters x=52 — the caret runs ahead of what you see.
 * MentionInput (the ONE comment box component) must cancel it. This test loads the REAL library under an
 * iPhone user agent, because the library decides at import time.
 */
import { describe, it, expect, vi, afterEach } from "vitest";
import { render } from "@testing-library/react";

vi.mock("@/lib/profilesPublic", () => ({ profilesPublic: () => ({ select: () => ({ ilike: () => ({ limit: async () => ({ data: [] }) }) }) }) }));

const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
const realUA = navigator.userAgent;

afterEach(() => {
  Object.defineProperty(navigator, "userAgent", { value: realUA, configurable: true });
  vi.resetModules();
});

describe("MentionInput on iPhone: the caret layer sits on the letters", () => {
  it("cancels react-mentions' iOS margin (no -3px left, no 1px down)", async () => {
    Object.defineProperty(navigator, "userAgent", { value: IPHONE, configurable: true });
    vi.resetModules();
    const { default: MentionInput } = await import("@/components/MentionInput");
    const { container } = render(<MentionInput value="" onChange={() => {}} placeholder="Add a comment" />);
    const ta = container.querySelector("textarea") as HTMLTextAreaElement;
    expect(ta).toBeTruthy();
    expect(ta.style.marginLeft).toBe("0px");
    expect(ta.style.marginTop).toBe("0px");
  });
});

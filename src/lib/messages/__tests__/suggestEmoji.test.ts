import { describe, expect, it } from "vitest";
import { suggestReplies } from "../suggest";
import { isEmojiOnly } from "../emoji";
import type { ThreadMessage } from "../api";

const m = (body: string, extra: Partial<ThreadMessage> = {}): ThreadMessage => ({ id: 1, senderId: "x", kind: "text", body, createdAt: "t", status: "sent", photos: [], ...extra });

describe("suggested replies", () => {
  it("answers a lens question like a photographer", () => {
    expect(suggestReplies(m("Which lens was that?"))[0]).toContain("50mm");
  });
  it("answers an invitation, a thank-you, a greeting and a photo", () => {
    expect(suggestReplies(m("Are you free this weekend?"))[0]).toMatch(/free/i);
    expect(suggestReplies(m("Thanks a lot!"))[0]).toMatch(/welcome/i);
    expect(suggestReplies(m("Hey there"))[0]).toMatch(/hi/i);
    expect(suggestReplies(m("", { kind: "photo" }))).toHaveLength(3);
  });
  it("offers at most three and nothing for held, empty or missing messages", () => {
    expect(suggestReplies(m("whatever")).length).toBeLessThanOrEqual(3);
    expect(suggestReplies(m("hi", { status: "held" }))).toEqual([]);
    expect(suggestReplies(m("   "))).toEqual([]);
    expect(suggestReplies(null)).toEqual([]);
  });
});

describe("emoji-only messages", () => {
  it("recognises one to three emoji only", () => {
    expect(isEmojiOnly("😍")).toBe(true);
    expect(isEmojiOnly("😍🔥 ❤️")).toBe(true);
    expect(isEmojiOnly("👍🏽")).toBe(true);
    expect(isEmojiOnly("😍😍😍😍")).toBe(false);
    expect(isEmojiOnly("nice 😍")).toBe(false);
    expect(isEmojiOnly("")).toBe(false);
  });
});

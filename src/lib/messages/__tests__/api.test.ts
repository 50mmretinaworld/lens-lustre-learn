import { describe, expect, it } from "vitest";
import { parseConversations, parseSendResult, parseThread, parseUnread, refusalFrom } from "../api";

describe("messages data layer", () => {
  it("maps the server's refusal codes", () => {
    expect(refusalFrom("MSG-040: you can message members you follow")).toBe("no_link");
    expect(refusalFrom("ACCOUNT_UNDER_REVIEW")).toBe("under_review");
    expect(refusalFrom("MSG-060: this message cannot be sent")).toBe("word_guard");
    expect(refusalFrom("MSG-023: photos")).toBe("photos_off");
    expect(refusalFrom("something else")).toBe("unknown");
    expect(refusalFrom(undefined)).toBe("unknown");
  });

  it("drops malformed rows instead of half-showing them", () => {
    expect(parseConversations("x")).toEqual([]);
    expect(parseConversations([{ nope: 1 }, { conversation_id: "c1", unread: 2, other: { user_id: "u2", full_name: "Asha" } }])).toEqual([
      { conversationId: "c1", folder: "inbox", muted: false, lastMessageAt: null, other: { userId: "u2", fullName: "Asha", username: null, avatarUrl: null }, last: null, unread: 2 },
    ]);
    expect(parseThread([{ id: "1" }, { id: 7, sender_id: "u", created_at: "t", body: "<b>hi</b>", kind: "text" }])).toEqual([
      { id: 7, senderId: "u", kind: "text", body: "<b>hi</b>", createdAt: "t", status: "sent", photos: [] },
    ]);
  });

  it("keeps the body as plain text and only the sender's own held status", () => {
    const [m] = parseThread([{ id: 1, sender_id: "u", created_at: "t", body: "x", kind: "photo", status: "held", photos: [{ path: "u/a.webp", width: 4, height: 3 }, { nope: 1 }] }]);
    expect(m.status).toBe("held");
    expect(m.photos).toEqual([{ path: "u/a.webp", width: 4, height: 3 }]);
  });

  it("reads counts and send results defensively", () => {
    expect(parseUnread(null)).toEqual({ inbox: 0, requests: 0 });
    expect(parseUnread({ inbox: 3, requests: 1 })).toEqual({ inbox: 3, requests: 1 });
    expect(parseSendResult({ message_id: 5, conversation_id: "c", duplicate: false, status: "held", folder: "requests", help: true })).toEqual({
      messageId: 5, conversationId: "c", duplicate: false, status: "held", folder: "requests", help: true,
    });
    expect(parseSendResult({})).toBeNull();
  });
});

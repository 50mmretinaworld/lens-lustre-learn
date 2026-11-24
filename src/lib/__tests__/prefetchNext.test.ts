/**
 * N6-4 · the next screen starts loading on touch: code once per page load, first data into the screen's OWN query
 * entry (same key, same reader), nothing on a slow connection.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { QueryClient } from "@tanstack/react-query";

const fetchNotificationPage = vi.fn(async () => [{ group_key: "g1" }]);
const fetchConversations = vi.fn(async () => [{ conversationId: "c1" }]);
let slow = false;
let me: string | null = "u1";

vi.mock("@/pages/Notifications", () => ({ default: () => null }));
vi.mock("@/pages/MessagesRoutes", () => ({ default: () => null }));
vi.mock("@/pages/Competitions", () => ({ default: () => null }));
vi.mock("@/pages/Index", () => ({ default: () => null }));
vi.mock("@/hooks/notifications/useNotificationHistory", () => ({ fetchNotificationPage }));
vi.mock("@/lib/messages/api", () => ({ fetchConversations }));
vi.mock("@/lib/offline/networkQuality", () => ({ getNetState: () => ({ online: true, slow, reason: slow ? "hinted" : null }) }));
vi.mock("@/lib/logger", () => ({ getLogUser: () => me }));

import { installPrefetchNext, prefetchPath, resetPrefetchForTests, setPrefetchQueryClient } from "@/lib/prefetchNext";

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("N6-4 prefetchNext", () => {
  let qc: QueryClient;
  beforeEach(() => {
    resetPrefetchForTests();
    fetchNotificationPage.mockClear();
    fetchConversations.mockClear();
    slow = false;
    me = "u1";
    qc = new QueryClient();
    setPrefetchQueryClient(qc);
  });

  it("notifications: the first page lands in the screen's own entry, once per page load", async () => {
    prefetchPath("/notifications");
    prefetchPath("/notifications");
    await vi.waitFor(() => expect(qc.getQueryData(["notification-history", "u1"])).toBeTruthy());
    expect(fetchNotificationPage).toHaveBeenCalledTimes(1);
    expect(fetchNotificationPage).toHaveBeenCalledWith(null);
    const data = qc.getQueryData<{ pages: unknown[] }>(["notification-history", "u1"]);
    expect(data?.pages?.[0]).toEqual([{ group_key: "g1" }]);
  });

  it("messages: the chat list lands in the list's own entry (inbox, first 30)", async () => {
    prefetchPath("/messages");
    await vi.waitFor(() => expect(qc.getQueryData(["messages", "conversations", "u1", "inbox"])).toBeTruthy());
    expect(fetchConversations).toHaveBeenCalledWith("inbox", 30);
    expect(qc.getQueryData(["messages", "conversations", "u1", "inbox"])).toEqual([{ conversationId: "c1" }]);
  });

  it("nothing on a slow connection, and no data when signed out", async () => {
    slow = true;
    prefetchPath("/notifications");
    await flush();
    expect(fetchNotificationPage).not.toHaveBeenCalled();
    slow = false; me = null;
    prefetchPath("/messages");
    await flush();
    expect(fetchConversations).not.toHaveBeenCalled();
  });

  it("a touch on a button marked data-prefetch, or on a link, starts it", async () => {
    installPrefetchNext();
    const b = document.createElement("button");
    b.setAttribute("data-prefetch", "/notifications");
    document.body.appendChild(b);
    b.dispatchEvent(new Event("touchstart", { bubbles: true }));
    const a = document.createElement("a");
    a.href = "/messages";
    document.body.appendChild(a);
    a.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    await vi.waitFor(() => { expect(fetchNotificationPage).toHaveBeenCalled(); expect(fetchConversations).toHaveBeenCalled(); });
    expect(fetchNotificationPage).toHaveBeenCalledTimes(1);
    expect(fetchConversations).toHaveBeenCalledTimes(1);
  });
});

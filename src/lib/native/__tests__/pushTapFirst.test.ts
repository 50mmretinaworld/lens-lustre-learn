/**
 * A tapped notification must not wait for the network (Owner 26 Nov 2026: "tapping it does not land in the chat").
 * src/lib/native/push.ts listens for taps before it asks for permission, a token or the registration.
 */
import { describe, it, expect, vi, afterEach } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: async () => ({ error: null }) } }));

import { initPushNotifications, unregisterPushNotifications } from "@/lib/native/push";

type Tap = (e: Record<string, unknown>) => void;

function app({ getToken, receive = "granted" }: { getToken: () => Promise<{ token: string }>; receive?: string }) {
  const taps: Tap[] = [];
  (window as unknown as { Capacitor: unknown }).Capacitor = {
    isNativePlatform: () => true,
    getPlatform: () => "android",
    Plugins: {
      FirebaseMessaging: {
        requestPermissions: async () => ({ receive }),
        getToken,
        addListener: async (event: string, cb: Tap) => {
          if (event === "notificationActionPerformed") taps.push(cb);
          return { remove: () => {} };
        },
        removeAllListeners: async () => {},
        deleteToken: async () => {},
      },
    },
  };
  return taps;
}

const tapped = { notification: { data: { type: "new_message", reference_id: "chat-1" } } };

afterEach(async () => {
  const fm = (window as unknown as { Capacitor?: { Plugins: { FirebaseMessaging: { getToken: unknown } } } }).Capacitor;
  if (fm) fm.Plugins.FirebaseMessaging.getToken = async () => ({ token: "t" });
  await unregisterPushNotifications();
  delete (window as unknown as { Capacitor?: unknown }).Capacitor;
});

describe("push.ts — taps are heard first", () => {
  it("opens the chat while the token is still on its way", async () => {
    const taps = app({ getToken: () => new Promise(() => {}) });
    const onOpen = vi.fn();
    void initPushNotifications(onOpen);
    await vi.waitFor(() => expect(taps).toHaveLength(1));
    taps[0](tapped);
    expect(onOpen).toHaveBeenCalledWith(tapped.notification.data);
  });

  it("still opens the chat when the token call fails", async () => {
    const taps = app({ getToken: async () => { throw new Error("offline"); } });
    const onOpen = vi.fn();
    await initPushNotifications(onOpen);
    taps[0](tapped);
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("never listens twice, and a later try uses the newest handler", async () => {
    const taps = app({ getToken: async () => ({ token: "t" }), receive: "denied" });
    const first = vi.fn();
    const second = vi.fn();
    await initPushNotifications(first);
    await initPushNotifications(second);
    expect(taps).toHaveLength(1);
    taps[0](tapped);
    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledTimes(1);
  });
});

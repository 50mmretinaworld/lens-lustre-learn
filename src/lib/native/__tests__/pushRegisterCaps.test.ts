/**
 * PN4 · what this build tells the server it can show (src/lib/native/push.ts →
 * register_push_device caps). A build with the PushCentre plugin draws rich
 * admin pushes, so it registers caps ['rich']; a database without the new
 * function still gets the device through the old call.
 */
import { describe, it, expect, vi, afterEach } from "vitest";

const state = vi.hoisted(() => ({
  calls: [] as Array<{ fn: string; args: Record<string, unknown> }>,
  failNew: false,
}));

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc: async (fn: string, args: Record<string, unknown>) => {
      state.calls.push({ fn, args });
      if (fn === "register_push_device" && state.failNew) return { error: { code: "PGRST202", message: "not found" } };
      return { error: null };
    },
  },
}));

import { initPushNotifications, unregisterPushNotifications } from "@/lib/native/push";

function app({ pushCentre }: { pushCentre: boolean }) {
  (window as unknown as { Capacitor: unknown }).Capacitor = {
    isNativePlatform: () => true,
    getPlatform: () => "android",
    Plugins: {
      App: { getInfo: async () => ({ version: "1.2.50" }) },
      FirebaseMessaging: {
        requestPermissions: async () => ({ receive: "granted" }),
        getToken: async () => ({ token: "tok-1" }),
        addListener: async () => ({ remove: () => {} }),
        removeAllListeners: async () => {},
        deleteToken: async () => {},
      },
      ...(pushCentre
        ? { PushCentre: { status: async () => ({ enabled: true, rich: true }), openSettings: async () => {} } }
        : {}),
    },
  };
}

const call = (fn: string) => state.calls.find((c) => c.fn === fn);

afterEach(async () => {
  await unregisterPushNotifications();
  delete (window as unknown as { Capacitor?: unknown }).Capacitor;
  state.calls.length = 0;
  state.failNew = false;
});

describe("push.ts — what this build tells the server it can show", () => {
  it("a build with the push centre registers caps ['rich'] and its version", async () => {
    app({ pushCentre: true });
    await initPushNotifications();
    expect(call("register_push_device")?.args).toMatchObject({
      _token: "tok-1", _platform: "android", _app_version: "1.2.50", _caps: ["rich"],
    });
    await vi.waitFor(() => expect(call("report_push_permission")?.args).toMatchObject({ _permission: "granted" }));
  });

  it("a build without it registers no caps (plain pushes only)", async () => {
    app({ pushCentre: false });
    await initPushNotifications();
    expect(call("register_push_device")?.args).toMatchObject({ _caps: [] });
  });

  it("a database without register_push_device still gets the device (old call)", async () => {
    app({ pushCentre: true });
    state.failNew = true;
    await initPushNotifications();
    expect(call("register_push_token")?.args).toEqual({ _token: "tok-1", _platform: "android" });
  });
});

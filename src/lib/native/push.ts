// Push notifications (Firebase Cloud Messaging) for the installed Android/iOS app.
//
// IMPORTANT — WHY THERE ARE NO @capacitor/* IMPORTS HERE:
// The Capacitor packages are NOT dependencies in package.json; they are installed
// only inside the Android CI job (.github/workflows/android-build.yml). A static
// `import ... from '@capacitor/core'` therefore breaks the WEB build the moment
// anything imports this file — which is exactly why the previous version of this
// module could never be called from App.tsx and no device ever registered.
//
// So this file follows the same proven pattern as authDeepLink.ts: reach the
// plugins through the `window.Capacitor` runtime globals that exist only inside
// the installed app. On web every export below is a harmless no-op.

import { supabase } from "@/integrations/supabase/client";
import { logger } from "@/lib/logger";
import { reportPushOpened } from "@/lib/notifications/pushOpened";

const FILE = "src/lib/native/push.ts";
import { isNativeCapacitorApp } from "@/lib/native/authDeepLink";
import { pushCentre, pushStatus } from "@/lib/native/pushCentre";

type PushToken = { token?: string };

type FirebaseMessagingPlugin = {
  requestPermissions: () => Promise<{ receive?: string }>;
  getToken: () => Promise<PushToken>;
  deleteToken?: () => Promise<void>;
  addListener: (
    event: "tokenReceived" | "notificationActionPerformed",
    cb: (e: Record<string, unknown>) => void,
  ) => Promise<unknown> | unknown;
  removeAllListeners?: () => Promise<void>;
};

type CapGlobal = {
  getPlatform?: () => string;
  Plugins?: {
    FirebaseMessaging?: FirebaseMessagingPlugin;
    App?: { getInfo?: () => Promise<{ version?: string }> };
  };
};

const cap = (): CapGlobal | undefined =>
  (window as unknown as { Capacitor?: CapGlobal }).Capacitor;

const messaging = (): FirebaseMessagingPlugin | undefined =>
  cap()?.Plugins?.FirebaseMessaging;

const platform = (): string => {
  try {
    return cap()?.getPlatform?.() || "android";
  } catch {
    return "android";
  }
};

let started = false;
/** The tap handler of the last init call, so a later retry routes taps the same way. */
let lastOnOpen: ((data: Record<string, unknown>) => void) | undefined;

/**
 * PN4 · what this build can show. "rich" (live countdown, buttons, picture
 * slides) only when the native PushRichService is in the build — the
 * PushCentre plugin ships with it.
 */
async function deviceInfo(): Promise<{ version: string | null; caps: string[] }> {
  let version: string | null = null;
  try {
    version = (await cap()?.Plugins?.App?.getInfo?.())?.version ?? null;
  } catch {
    /* unknown version is fine */
  }
  if (version && !/^[0-9A-Za-z._-]{1,32}$/.test(version)) version = null;
  return { version, caps: pushCentre() ? ["rich"] : [] };
}

/**
 * Store the token WITH what the build can show (20261116_1500). A database
 * that does not have that function yet — or refuses the extra fields — gets
 * the old call, so a device is never left unregistered.
 */
async function registerToken(token: string): Promise<void> {
  const { version, caps } = await deviceInfo();
  const { error } = await supabase.rpc("register_push_device" as never, {
    _token: token,
    _platform: platform(),
    _app_version: version,
    _caps: caps,
  } as never);
  if (!error) return;
  await supabase.rpc("register_push_token" as never, {
    _token: token,
    _platform: platform(),
  } as never);
}

/**
 * Tell the server the member's answer, so Admin → Push Notification can say
 * "said No" instead of guessing. Never blocks or fails setup.
 */
async function reportPermission(answer: "granted" | "denied"): Promise<void> {
  try {
    const { version } = await deviceInfo();
    await supabase.rpc("report_push_permission" as never, {
      _permission: answer,
      _platform: platform(),
      _app_version: version,
    } as never);
  } catch {
    /* a report is never allowed to break push setup */
  }
}

/**
 * Run setup again with the same tap handler — the "Turn on notifications"
 * card calls this when the member comes back from the phone's settings.
 */
export function retryPushSetup(): Promise<void> {
  return initPushNotifications(lastOnOpen);
}

/**
 * Ask for notification permission (once), register this device's FCM token so
 * the server can reach it, and route taps on a delivered notification.
 *
 * Safe to call on every login and on web — it returns immediately unless we are
 * inside the installed app AND the messaging plugin is present.
 *
 * @param onOpen receives the `data` payload of a tapped notification, e.g.
 *               { type: "post_comment", reference_id: "<post uuid>" }.
 */
export async function initPushNotifications(
  onOpen?: (data: Record<string, unknown>) => void,
): Promise<void> {
  if (onOpen) lastOnOpen = onOpen;
  if (!isNativeCapacitorApp() || started) return;
  const fm = messaging();
  if (!fm) return; // plugin not in this build — nothing to do

  started = true;
  try {
    // Android 13+ / iOS show the OS permission prompt here. Declining is final
    // until the user changes it in system settings, so we never re-prompt —
    // the "Turn on notifications" card (PushPermissionCard) is the way back.
    const perm = await fm.requestPermissions();
    // Android 12 and older answer "granted" even when the member blocked the
    // app's notifications in settings; the phone's own switch is the truth.
    const phone = await pushStatus();
    if (perm?.receive !== "granted" || phone?.enabled === false) {
      void reportPermission("denied");
      started = false;
      return;
    }
    void reportPermission("granted");

    const { token } = await fm.getToken();
    if (token) await registerToken(token);

    // FCM rotates tokens; persist the new one when it does.
    await fm.addListener("tokenReceived", async (e: Record<string, unknown>) => {
      const t = (e as { token?: string })?.token;
      if (t) await registerToken(t);
    });

    // Tap on a notification → hand the payload to the caller for deep-linking.
    await fm.addListener("notificationActionPerformed", (e: Record<string, unknown>) => {
      const notification = (e as { notification?: { data?: Record<string, unknown> } })?.notification;
      onOpen?.(notification?.data ?? {});
      void reportPushOpened(notification?.data ?? {});   // N4 receipt; no-op without delivery_id
    });
  } catch (err) {
    logger.error({
      code: "NOTIF-7001",
      event: "PUSH_INIT_FAILED",
      fn: "startPush",
      file: FILE,
      message: "Push notification setup failed inside the installed app.",
      reason: err instanceof Error ? err.message : String(err),
      expected: "Permission granted, a token registered, and listeners attached",
      actual: "Setup threw part-way through",
      nextStep:
        "NOTHING TELLS THE MEMBER — they will simply never receive a push and will assume the app is quiet. Check whether a row exists in push_tokens for them.",
    });
    started = false;
  }
}

/**
 * Call on logout so the device stops receiving the previous user's pushes.
 * Matters on shared phones.
 */
export async function unregisterPushNotifications(): Promise<void> {
  if (!isNativeCapacitorApp()) return;
  const fm = messaging();
  if (!fm) return;

  try {
    const { token } = await fm.getToken();
    if (token) {
      await supabase.rpc("unregister_push_token" as never, { _token: token } as never);
    }
    await fm.deleteToken?.();
  } catch {
    /* best-effort — never block logout */
  }
  try {
    await fm.removeAllListeners?.();
  } catch {
    /* noop */
  }
  started = false;
}

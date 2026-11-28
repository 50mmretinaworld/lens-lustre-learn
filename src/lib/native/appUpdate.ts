// In-app update support (Google Play In-App Updates) for the Capacitor
// Android app, via @capawesome/capacitor-app-update.
//
// IMPORTANT: this file must NOT import any @capacitor/* or @capawesome/*
// package. Those npm packages are only installed in the Android CI build
// (see .github/workflows/android-build.yml), not in the web deploy — so we
// talk to the native bridge exclusively through the `window.Capacitor`
// runtime globals that exist only inside the installed app. On the web/PWA
// every function here is a silent no-op. (Same pattern as authDeepLink.ts.)

import { logger } from "@/lib/logger";
import { recordTiming } from "@/lib/telemetry";

const FILE = "src/lib/native/appUpdate.ts";

type AppUpdatePlugin = {
  getAppUpdateInfo: () => Promise<{
    updateAvailability?: number; // 2 = UPDATE_AVAILABLE (AppUpdateAvailability enum)
    immediateUpdateAllowed?: boolean;
    flexibleUpdateAllowed?: boolean;
    currentVersionCode?: string;
    availableVersionCode?: string;
    currentVersionName?: string;
    availableVersionName?: string;
  }>;
  performImmediateUpdate: () => Promise<{ code?: number }>;
  // iOS: appId (the numeric Apple ID) is REQUIRED by the plugin; Android ignores it.
  openAppStore: (options?: { appId?: string }) => Promise<void>;
};

// iOS has no in-app update: the prompt opens the App Store page instead, which needs the app's numeric Apple ID
// (App Store Connect → App Information → Apple ID). ios-build.yml passes it from the repo variable IOS_APP_STORE_ID.
// Without it the iOS prompt stays off (it could not open the store).
const IOS_APP_STORE_ID: string = (import.meta.env.VITE_IOS_APP_STORE_ID ?? "").trim();

type CapGlobal = {
  isNativePlatform?: () => boolean;
  getPlatform?: () => string;
  Plugins?: Record<string, unknown>;
};

const cap = (): CapGlobal | undefined =>
  (window as unknown as { Capacitor?: CapGlobal }).Capacitor;

const plugin = (): AppUpdatePlugin | undefined =>
  cap()?.Plugins?.AppUpdate as AppUpdatePlugin | undefined;

const isIos = (): boolean => cap()?.getPlatform?.() === "ios";

/** True only inside the installed Android app, or the iOS app when its Apple ID is known, with the plugin present. */
export const appUpdateSupported = (): boolean => {
  if (!cap()?.isNativePlatform?.() || !plugin()) return false;
  const platform = cap()?.getPlatform?.();
  return platform === "android" || (platform === "ios" && /^\d+$/.test(IOS_APP_STORE_ID));
};

/** The store the update comes from, for the prompt's wording. */
export const appStoreName = (): string => (isIos() ? "the App Store" : "Google Play");

export interface UpdateStatus {
  available: boolean;
  immediateAllowed: boolean;
  availableVersion?: string;
}

/** Ask Google Play whether a newer version of the app exists. */
export async function checkForAppUpdate(): Promise<UpdateStatus | null> {
  // Owner bug list item 5 (28 Nov): the popup did not come for 1.2.63 and nothing said why. Every check in the
  // app now leaves one record: app.update.<Play's answer>, app.update.failed, or app.update.no_plugin.
  // Play's answer codes: 1 = no update, 2 = update available, 3 = an update is already being installed, 0 = unknown.
  if (cap()?.isNativePlatform?.() && !plugin()) recordTiming("app.update.no_plugin", 0, false);
  if (!appUpdateSupported()) return null;
  const started = Date.now();
  try {
    const info = await plugin()!.getAppUpdateInfo();
    recordTiming(`app.update.${Number(info.updateAvailability ?? 0) || 0}`, Date.now() - started, true);
    return {
      available: info.updateAvailability === 2, // UPDATE_AVAILABLE
      immediateAllowed: !isIos() && !!info.immediateUpdateAllowed,
      availableVersion: info.availableVersionName ?? info.availableVersionCode,
    };
  } catch (err) {
    recordTiming("app.update.failed", Date.now() - started, false);
    logger.warn({
      code: "SYS-9008",
      event: "APP_UPDATE_CHECK_FAILED",
      fn: "checkForUpdate",
      file: FILE,
      message: "The installed app could not ask Play whether an update exists.",
      reason: err instanceof Error ? err.message : String(err),
      expected: "Play to report whether a newer build is available",
      actual: "The check threw",
      nextStep:
        "Harmless once; persistent hits mean members are stranded on an old build, which is how an already-fixed bug keeps being reported.",
    });
    return null;
  }
}

/**
 * Run the update. Prefers Google Play's IMMEDIATE in-app flow (fullscreen
 * Play sheet, downloads + installs without leaving the app); falls back to
 * opening the Play Store listing.
 */
export async function startAppUpdate(immediateAllowed: boolean): Promise<void> {
  const p = plugin();
  if (!p) return;
  try {
    if (immediateAllowed && !isIos()) {
      await p.performImmediateUpdate();
      return;
    }
  } catch (err) {
    logger.warn({
      code: "SYS-9009",
      event: "APP_UPDATE_IMMEDIATE_FLOW_FAILED",
      fn: "startUpdate",
      file: FILE,
      message: "The in-app update flow failed; falling back to the store listing.",
      reason: err instanceof Error ? err.message : String(err),
      expected: "Play's immediate update flow to run inside the app",
      actual: "The flow threw; the store listing is the fallback",
      nextStep:
        "The member can still update, just with more steps. Only urgent if the store fallback (SYS-9010) also fails.",
    });
  }
  try {
    await (isIos() ? p.openAppStore({ appId: IOS_APP_STORE_ID }) : p.openAppStore());
  } catch (err) {
    logger.error({
      code: "SYS-9010",
      event: "APP_UPDATE_STORE_OPEN_FAILED",
      fn: "startUpdate",
      file: FILE,
      message: "The app could not open the store listing, so the member has no way to update.",
      reason: err instanceof Error ? err.message : String(err),
      expected: "The Play listing to open",
      actual: "Both the in-app flow and the store fallback failed",
      nextStep:
        "END OF THE LINE — the member is stuck on their current build and nothing on screen tells them so. Pair this with SYS-9009 in the same correlation window to see the whole flow fail.",
    });
  }
}

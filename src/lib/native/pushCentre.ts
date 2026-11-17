// PUSH CENTRE PN4 · the web side of PushCentrePlugin
// (resources/android/java/com/fiftymmretina/app/PushCentrePlugin.java).
//
// Reached through window.Capacitor only — no @capacitor/* import (same rule as
// authDeepLink.ts), so the website build stays clean. On the web, and in app
// builds before 1.2.50, the plugin is absent and every export answers
// "not available" without throwing.
//
// The plugin's PRESENCE is also how push.ts knows this build draws rich admin
// pushes (live countdown, buttons, picture slides): the plugin and
// PushRichService are installed together by scripts/android-native-plugins.mjs.

type PushCentrePlugin = {
  status: () => Promise<{ enabled?: boolean; rich?: boolean }>;
  openSettings: () => Promise<void>;
};

export const pushCentre = (): PushCentrePlugin | undefined =>
  (window as unknown as { Capacitor?: { Plugins?: { PushCentre?: PushCentrePlugin } } }).Capacitor?.Plugins?.PushCentre;

/** Are notifications allowed for the app right now? null = this build cannot tell. */
export async function pushStatus(): Promise<{ enabled: boolean; rich: boolean } | null> {
  const p = pushCentre();
  if (!p) return null;
  try {
    const s = await p.status();
    return { enabled: s?.enabled === true, rich: s?.rich === true };
  } catch {
    return null;
  }
}

/** Open this app's notification settings on the phone. false = could not. */
export async function openPushSettings(): Promise<boolean> {
  const p = pushCentre();
  if (!p) return false;
  try {
    await p.openSettings();
    return true;
  } catch {
    return false;
  }
}

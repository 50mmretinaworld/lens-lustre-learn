import type { CapacitorConfig } from '@capacitor/cli';

// NOTE: appId is your permanent bundle identifier once published — change it now
// if you want a different one (must be reverse-domain; no segment may start with a
// digit, which is why it's not "com.50mmretina"). appName shows under the icon.
const config: CapacitorConfig = {
  appId: 'com.fiftymmretina.app',
  appName: '50mm Retina World',
  webDir: 'dist',
  server: {
    androidScheme: 'https',
  },
  android: {
    // Proper edge-to-edge on Android 15+ (target SDK 36): the WebView gets
    // margins for the status/navigation bars instead of the deprecated
    // opt-out flag the platform template ships (which Play flags as
    // "may not display for all users" + "deprecated APIs or parameters").
    adjustMarginsForEdgeToEdge: 'auto',
  },
  ios: {
    // The iPhone status bar (time, signal, battery, notch) must never sit on top of the app's
    // header, the "+" button or a story's top bar. Capacitor's default ('never') lets the web
    // page run under it and nothing in the CSS reserves that strip (Owner photos, 23 Nov 2026:
    // clock and battery drawn over "50mm Retina World", the "+" and the story name). 'always'
    // makes the page start below the status bar and above the home bar, on every screen at once.
    // Android is untouched. backgroundColor = the dark app background, so the strip matches.
    contentInset: 'always',
    backgroundColor: '#0f172a',
  },
  plugins: {
    // FCM presentation while the app is foregrounded
    FirebaseMessaging: {
      presentationOptions: ['badge', 'sound', 'alert'],
    },
    SplashScreen: {
      launchShowDuration: 800,
      backgroundColor: '#0b1020',
      showSpinner: false,
    },
  },
};

export default config;

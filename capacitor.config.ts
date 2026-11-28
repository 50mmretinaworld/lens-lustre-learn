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
    // iPhone (Owner bug list 27-28 Nov, item 2): with the keyboard open, the comment box, Sign in and Sign out
    // screens were pushed up behind the clock. 'native' shrinks the app's screen above the keyboard instead of
    // letting iOS slide the page up. Installed in the iPhone build only (ios-build.yml); Android ignores it.
    Keyboard: {
      resize: 'native',
      resizeOnFullScreen: true,
    },
  },
};

export default config;

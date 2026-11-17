package com.fiftymmretina.app;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.app.NotificationManagerCompat;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * PUSH CENTRE PN4 · what the web layer cannot find out or do by itself.
 *
 * Owner approved item 9 (16 Nov 2026): a "Turn on notifications" card for
 * members who said No, opening the phone's settings in one tap. Android never
 * shows the permission question a second time, so the settings page is the
 * only way back.
 *
 * Contract (asserted by src/lib/native/__tests__/pushCentreNative.test.ts):
 *   PushCentre.status()       -> { enabled: boolean, rich: true }
 *       enabled  notifications are allowed for this app right now (covers the
 *                Android 13 permission AND the older "blocked in settings").
 *       rich     this build draws rich admin pushes (PushRichService is in it).
 *   PushCentre.openSettings() -> opens this app's notification settings.
 *
 * Its presence is how the web layer knows the build can show rich pushes
 * (src/lib/native/push.ts registers the device with caps ["rich"]).
 * Copied and registered by scripts/android-native-plugins.mjs.
 */
@CapacitorPlugin(name = "PushCentre")
public class PushCentrePlugin extends Plugin {

    @PluginMethod
    public void status(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("enabled", NotificationManagerCompat.from(getContext()).areNotificationsEnabled());
        ret.put("rich", true);
        call.resolve(ret);
    }

    @PluginMethod
    public void openSettings(PluginCall call) {
        String pkg = getContext().getPackageName();
        try {
            Intent i;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                i = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, pkg);
            } else {
                i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", pkg, null));
            }
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            call.resolve();
        } catch (Exception e) {
            call.reject("notification settings unavailable", "PUSH_SETTINGS_UNAVAILABLE");
        }
    }
}

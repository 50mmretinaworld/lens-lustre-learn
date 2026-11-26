package com.fiftymmretina.app;

import androidx.annotation.NonNull;
import com.google.firebase.messaging.RemoteMessage;
import io.capawesome.capacitorjs.plugins.firebase.messaging.MessagingService;
import java.util.Map;

/**
 * PUSH CENTRE PN4 · receives every push for the app.
 *
 * An admin push for this build arrives as a DATA-ONLY message with
 * type = "broadcast_rich" (supabase/functions/_shared/broadcastMessage.ts).
 * Android draws nothing for a data-only message, so PushRichNotifier draws it:
 * live countdown, buttons, picture slides. Every other message goes to the
 * push plugin's own service exactly as before (token refresh included —
 * onNewToken is inherited).
 *
 * The manifest names THIS class for com.google.firebase.MESSAGING_EVENT and
 * removes the plugin's entry (scripts/android-native-plugins.mjs): Android
 * hands a push to one service only.
 */
public class PushRichService extends MessagingService {

    @Override
    public void onMessageReceived(@NonNull RemoteMessage message) {
        Map<String, String> data = message.getData();
        if (PushRichNotifier.TYPE.equals(data.get("type"))) {
            PushRichNotifier.show(getApplicationContext(), data);
            return;
        }
        if (PushRichNotifier.CHAT_TYPE.equals(data.get("type"))) {
            PushRichNotifier.showChat(getApplicationContext(), data);
            return;
        }
        super.onMessageReceived(message);
    }
}

package com.fiftymmretina.app;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Build;
import android.os.SystemClock;
import android.view.View;
import android.widget.RemoteViews;
import androidx.core.app.NotificationCompat;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * PUSH CENTRE PN4 · draws one rich admin push (Owner approved items 7, 8, 10
 * on 16 Nov 2026: live countdown, buttons, picture slides).
 *
 * Data keys (all strings; built by buildBroadcastMessage, rich branch):
 *   title, body          text
 *   link                 "/…" opened on a tap
 *   origin               "https://www.50mmretina.com" — the site the link is on
 *   image                one picture (https)
 *   images               JSON ["https://…", …] — up to 5 slides
 *   countdown_until      end time, ms since 1970
 *   actions              JSON [{"label":"Enter now","link":"/…"}, …] — up to 2
 *   broadcast_id         one notification per broadcast (a re-send replaces it)
 *   delivery_id          receipt id; sent back as ?pn=<id> so "opened" is counted
 *
 * A tap opens MainActivity with an https VIEW link, which the app-link layer
 * (src/lib/native/appLinkOpen.ts) turns into the in-app page — the same road
 * an e-mail link takes. No second way to open a page.
 *
 * NEVER THROWS: any failure falls back to a plain title + text notification.
 * A push that crashes the service shows nothing at all.
 */
final class PushRichNotifier {

    static final String TYPE = "broadcast_rich";
    private static final String CHANNEL_ID = "updates";
    private static final String TAG = "broadcast";
    private static final int MAX_SLIDES = 5;
    private static final int MAX_BYTES = 3 * 1024 * 1024;
    private static final long PICTURE_BUDGET_MS = 9000;

    private PushRichNotifier() {}

    static void show(Context ctx, Map<String, String> d) {
        String title = d.get("title");
        if (title == null || title.trim().isEmpty()) return;
        if (Build.VERSION.SDK_INT >= 33
            && ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            return; // the member said No — Android would drop it anyway
        }
        try {
            post(ctx, d, rich(ctx, d, title));
        } catch (Throwable richFailed) {
            try {
                post(ctx, d, base(ctx, d, title));
            } catch (Throwable ignored) {
                // nothing more to try
            }
        }
    }

    /** Title, text, icon, tap target — what every variant starts from. */
    private static NotificationCompat.Builder base(Context ctx, Map<String, String> d, String title) {
        String body = d.get("body") == null ? "" : d.get("body");
        int icon = ctx.getResources().getIdentifier("ic_notification", "drawable", ctx.getPackageName());
        int colorRes = ctx.getResources().getIdentifier("notification_accent", "color", ctx.getPackageName());
        NotificationCompat.Builder b = new NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(icon != 0 ? icon : ctx.getApplicationInfo().icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_PROMO)
            .setContentIntent(open(ctx, d, d.get("link"), 0));
        if (colorRes != 0) b.setColor(ctx.getColor(colorRes));
        return b;
    }

    private static NotificationCompat.Builder rich(Context ctx, Map<String, String> d, String title) throws Exception {
        NotificationCompat.Builder b = base(ctx, d, title);
        String body = d.get("body") == null ? "" : d.get("body");
        long now = System.currentTimeMillis();
        long end = parseLong(d.get("countdown_until"));
        boolean countdown = end > now + 5000;

        // 7 · live countdown: the header clock ticks down, and the push leaves at the end
        if (countdown) {
            b.setWhen(end).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
                .setTimeoutAfter(end - now);
        }

        // 8 · buttons
        String actions = d.get("actions");
        if (actions != null && !actions.isEmpty()) {
            JSONArray list = new JSONArray(actions);
            for (int i = 0; i < list.length() && i < 2; i++) {
                JSONObject a = list.getJSONObject(i);
                String label = a.optString("label", "").trim();
                String link = a.optString("link", "");
                if (label.isEmpty() || link.isEmpty()) continue;
                b.addAction(0, label, open(ctx, d, link, i + 1));
            }
        }

        // 10 · pictures: slides when there are several, one big picture otherwise
        List<String> urls = new ArrayList<>();
        String images = d.get("images");
        if (images != null && !images.isEmpty()) {
            JSONArray list = new JSONArray(images);
            for (int i = 0; i < list.length() && urls.size() < MAX_SLIDES; i++) urls.add(list.getString(i));
        }
        if (urls.isEmpty() && d.get("image") != null) urls.add(d.get("image"));

        List<Bitmap> pictures = new ArrayList<>();
        long started = SystemClock.elapsedRealtime();
        for (String u : urls) {
            if (SystemClock.elapsedRealtime() - started > PICTURE_BUDGET_MS) break;
            Bitmap bmp = fetch(u, urls.size() > 1 ? 640 : 960);
            if (bmp != null) pictures.add(bmp);
        }
        if (!pictures.isEmpty()) b.setLargeIcon(pictures.get(0));

        if (countdown || pictures.size() > 1) {
            // one expanded layout: text, a large ticking clock, the slides
            RemoteViews big = new RemoteViews(ctx.getPackageName(), R.layout.push_rich_big);
            big.setTextViewText(R.id.push_title, title);
            big.setTextViewText(R.id.push_body, body);
            big.setViewVisibility(R.id.push_body, body.isEmpty() ? View.GONE : View.VISIBLE);
            if (countdown) {
                big.setViewVisibility(R.id.push_timer_box, View.VISIBLE);
                big.setTextViewText(R.id.push_timer_label, "Ends in");
                big.setChronometerCountDown(R.id.push_timer, true);
                big.setChronometer(R.id.push_timer, SystemClock.elapsedRealtime() + (end - now), null, true);
            }
            if (!pictures.isEmpty()) {
                big.setViewVisibility(R.id.push_flipper, View.VISIBLE);
                for (Bitmap bmp : pictures) {
                    RemoteViews slide = new RemoteViews(ctx.getPackageName(), R.layout.push_rich_slide);
                    slide.setImageViewBitmap(R.id.push_slide_image, bmp);
                    big.addView(R.id.push_flipper, slide);
                }
            }
            b.setStyle(new NotificationCompat.DecoratedCustomViewStyle()).setCustomBigContentView(big);
        } else if (pictures.size() == 1) {
            b.setStyle(new NotificationCompat.BigPictureStyle()
                .bigPicture(pictures.get(0)).bigLargeIcon((Bitmap) null).setSummaryText(body));
        }
        return b;
    }

    private static void post(Context ctx, Map<String, String> d, NotificationCompat.Builder b) {
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                new NotificationChannel(CHANNEL_ID, "News and offers", NotificationManager.IMPORTANCE_HIGH));
        }
        nm.notify(TAG, notificationId(d), b.build());
    }

    private static int notificationId(Map<String, String> d) {
        return 5000 + (int) (Math.abs(parseLong(d.get("broadcast_id"))) % 100000);
    }

    /**
     * A tap: MainActivity with an https VIEW link on this site, so the app-link
     * layer opens the page; ?pn=<receipt> lets it count the open. Anything that
     * is not "/…" on an https origin just opens the app.
     */
    private static PendingIntent open(Context ctx, Map<String, String> d, String link, int slot) {
        Intent i = new Intent(ctx, MainActivity.class);
        String origin = d.get("origin");
        boolean inSite = link != null && link.startsWith("/") && !link.startsWith("//")
            && origin != null && origin.startsWith("https://") && !origin.endsWith("/");
        if (inSite) {
            String url = origin + link;
            String receipt = d.get("delivery_id");
            if (receipt != null && receipt.matches("[0-9]{1,16}") && !link.contains("#")) {
                url += (link.contains("?") ? "&" : "?") + "pn=" + receipt;
            }
            i.setAction(Intent.ACTION_VIEW);
            i.setData(Uri.parse(url));
        } else {
            i.setAction(Intent.ACTION_MAIN);
            i.addCategory(Intent.CATEGORY_LAUNCHER);
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        // one PendingIntent per broadcast and slot (0 = the push itself, 1-2 = its buttons)
        int code = notificationId(d) * 4 + slot;
        return PendingIntent.getActivity(ctx, code, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /** One https picture, at most MAX_BYTES, scaled to maxWidth. null on any problem. */
    private static Bitmap fetch(String url, int maxWidth) {
        HttpURLConnection c = null;
        try {
            URL u = new URL(url);
            if (!"https".equals(u.getProtocol())) return null;
            c = (HttpURLConnection) u.openConnection();
            c.setConnectTimeout(4000);
            c.setReadTimeout(5000);
            c.setInstanceFollowRedirects(false);
            if (c.getResponseCode() != 200 || c.getContentLength() > MAX_BYTES) return null;
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (InputStream in = c.getInputStream()) {
                byte[] buf = new byte[16 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                    if (out.size() > MAX_BYTES) return null;
                }
            }
            byte[] bytes = out.toByteArray();
            BitmapFactory.Options bounds = new BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inSampleSize = 1;
            while (bounds.outWidth / (o.inSampleSize * 2) >= maxWidth) o.inSampleSize *= 2;
            o.inPreferredConfig = Bitmap.Config.RGB_565;
            Bitmap bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, o);
            if (bmp == null) return null;
            if (bmp.getWidth() > maxWidth) {
                int h = Math.max(1, Math.round(bmp.getHeight() * (maxWidth / (float) bmp.getWidth())));
                Bitmap scaled = Bitmap.createScaledBitmap(bmp, maxWidth, h, true);
                if (scaled != bmp) bmp.recycle();
                bmp = scaled;
            }
            return bmp;
        } catch (Throwable t) {
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static long parseLong(String s) {
        try {
            return s == null ? 0L : Long.parseLong(s.trim());
        } catch (NumberFormatException e) {
            return 0L;
        }
    }
}

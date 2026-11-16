/**
 * PUSH CENTRE PN1 · the one place an ADMIN push (broadcast) is shaped.
 * Pure — pinned by src/__tests__/broadcastMessage.test.ts.
 *
 * Two shapes, chosen per device:
 *   plain  every app build in members' hands today. A normal notification
 *          (title, message, big picture) built by buildFcmMessage — the same
 *          builder send-push uses. A countdown becomes a fixed "Ends …" line.
 *   rich   builds that registered caps ['rich'] (register_push_device). A
 *          data-only message; the app's own notification code draws the live
 *          countdown, the buttons and the picture carousel. Data-only, because
 *          a message with a notification block is drawn by Android itself and
 *          never reaches the app's code while it is in the background.
 *
 * Pictures only from this lane's hosts (isSafeImageUrl); links and buttons only
 * to paths inside the site ("/…").
 */
import { buildFcmMessage, isSafeImageUrl, type FcmMessage } from "./pushMessage.ts";

export const RICH_CAP = "rich";

export interface BroadcastContent {
  id: number;
  title: string;
  body: string | null;
  image_url: string | null;
  images: string[] | null;
  link: string | null;
  countdown_until: string | null;
  actions: Array<{ label?: unknown; link?: unknown }> | null;
}

export interface DataOnlyMessage {
  token: string;
  data: Record<string, string>;
  android: { priority: "high"; ttl?: string };
}

export interface BroadcastDevice {
  token: string;
  caps?: string[] | null;
}

const SAFE_LINK = /^\/([A-Za-z0-9_-][A-Za-z0-9/_.?=&%#-]*)?$/;

export function safeLink(link: unknown): string | null {
  return typeof link === "string" && link.length <= 300 && SAFE_LINK.test(link) ? link : null;
}

/** "Ends 18 Nov, 6:00 pm IST" — members are in India; the plain line is fixed text. */
export function endsLine(iso: string): string | null {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  const s = new Intl.DateTimeFormat("en-IN", {
    timeZone: "Asia/Kolkata", day: "numeric", month: "short", hour: "numeric", minute: "2-digit", hour12: true,
  }).format(new Date(t));
  return `Ends ${s.toLowerCase().replace(/\b(\d+) ([a-z]{3})/, (_m, d, mo) => `${d} ${mo[0].toUpperCase()}${mo.slice(1)}`)} IST`;
}

export function buildBroadcastMessage(
  b: BroadcastContent,
  device: BroadcastDevice,
  opts: { deliveryId?: number | null; imageHosts: readonly string[]; test?: boolean; now?: number },
): FcmMessage | DataOnlyMessage {
  const title = (opts.test ? "Test · " : "") + b.title;
  const link = safeLink(b.link);
  const countdownMs = b.countdown_until ? Date.parse(b.countdown_until) : NaN;
  const now = opts.now ?? Date.now();
  const hasCountdown = Number.isFinite(countdownMs) && countdownMs > now;
  const rich = (device.caps ?? []).includes(RICH_CAP);

  if (!rich) {
    const ends = hasCountdown ? endsLine(b.countdown_until as string) : null;
    const body = [b.body ?? "", ends ?? ""].filter(Boolean).join("\n");
    return buildFcmMessage({
      token: device.token,
      title,
      body,
      data: { type: "broadcast", broadcast_id: String(b.id), ...(link ? { link } : {}) },
      imageUrl: b.image_url,
      imageHosts: opts.imageHosts,
      deliveryId: opts.deliveryId ?? null,
    });
  }

  const data: Record<string, string> = {
    type: "broadcast_rich",
    broadcast_id: String(b.id),
    title,
    body: b.body ?? "",
  };
  if (link) data.link = link;
  if (isSafeImageUrl(b.image_url, opts.imageHosts)) data.image = b.image_url as string;
  const images = (b.images ?? []).filter((u) => isSafeImageUrl(u, opts.imageHosts)).slice(0, 5);
  if (images.length) data.images = JSON.stringify(images);
  if (hasCountdown) data.countdown_until = String(countdownMs);
  const actions = (b.actions ?? [])
    .map((a) => ({ label: typeof a?.label === "string" ? a.label.trim().slice(0, 20) : "", link: safeLink(a?.link) }))
    .filter((a) => a.label && a.link)
    .slice(0, 2);
  if (actions.length) data.actions = JSON.stringify(actions);
  if (opts.deliveryId !== undefined && opts.deliveryId !== null) data.delivery_id = String(opts.deliveryId);

  const msg: DataOnlyMessage = { token: device.token, data, android: { priority: "high" } };
  // a countdown push is worthless after the end — FCM drops it if still undelivered
  if (hasCountdown) msg.android.ttl = `${Math.max(60, Math.floor((countdownMs - now) / 1000))}s`;
  return msg;
}

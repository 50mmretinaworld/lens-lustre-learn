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

/**
 * OWNER BUG 16 Nov 2026 — "I set /competitions and it does not open there".
 *
 * App builds up to 1.2.49 never read `data.link`. A tap goes through the
 * app's own table getNotifLink(type, reference_id) (src/lib/notificationLinks.ts),
 * and type "broadcast" is not in it, so EVERY admin push opened the dashboard.
 * Those builds stay in members' hands for months, so the link is ALSO sent as
 * a type (+ reference_id) that their table already understands. Builds from
 * 1.2.50 read `link` first and never look at this.
 *
 * A page with no entry here still opens the dashboard on old builds — the
 * composer says which pages are safe.
 */
export function legacyTapTarget(link: string | null | undefined): { type: string; reference_id?: string } {
  const safe = safeLink(link);
  if (!safe) return { type: "broadcast" };
  const seg = safe.split(/[?#]/)[0].split("/").filter(Boolean);
  /** "/x" → the list page; "/x/<id>" → that item; anything deeper → not known to old builds. */
  const listOrItem = (type: string) =>
    seg.length === 1 ? { type } : seg.length === 2 ? { type, reference_id: seg[1] } : { type: "broadcast" };
  const only = (type: string) => (seg.length === 1 ? { type } : { type: "broadcast" });
  if (seg.length === 0) return { type: "potd_featured" };                   // "/" → home
  switch (seg[0]) {
    case "feed": return only("new_post_from_following");
    case "post": return seg.length === 2 ? { type: "new_post_from_following", reference_id: seg[1] } : { type: "broadcast" };
    case "competitions": return listOrItem("new_competition");
    case "journal": return listOrItem("journal_published");
    case "courses": return listOrItem("course_published");
    case "friends": return only("friend_request");
    case "certificates": return only("badge_awarded");
    case "discover": return only("image_reaction");
    case "help-support": return only("ticket_reply");
    case "wallet": return only("deposit_approved");
    default: return { type: "broadcast" };                                  // "/dashboard" and unknown pages
  }
}

/** Pages a tap opens on EVERY app build (the first path part). The admin page lists them. */
export const LEGACY_TAP_PAGES = [
  "/", "/feed", "/post", "/competitions", "/journal", "/courses", "/friends", "/certificates", "/discover",
  "/help-support", "/wallet", "/dashboard",
] as const;

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
      // type (+ reference_id): where builds ≤ 1.2.49 open on a tap; link: builds from 1.2.50
      data: { ...legacyTapTarget(link), broadcast_id: String(b.id), ...(link ? { link } : {}) },
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

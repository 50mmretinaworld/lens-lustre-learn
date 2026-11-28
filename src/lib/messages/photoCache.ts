/**
 * Messages · this device's own copy of chat photos (Owner 21 Nov: "like WhatsApp" — the server keeps a photo 30 days,
 * afterwards only the devices that have it).
 *
 * The first time a chat photo is shown (or sent) on a device, its picture is stored here, keyed by its storage path.
 * Later the tile reads this copy first, so it still opens after the server has deleted the file.
 *
 * Honest limits: this is the browser's Cache Storage. The Android app keeps it with the app's data; a web browser MAY
 * clear it (low disk, "clear site data"), another phone or browser never has it. Every call is best-effort: a failure
 * means "no local copy", never an error on screen.
 */
const CACHE_NAME = "msg-photos-v1";

function cacheKey(path: string): string {
  return `${location.origin}/__msg-photo/${encodeURIComponent(path)}`;
}

function usable(): boolean {
  return typeof caches !== "undefined" && typeof location !== "undefined" && !!location.origin && location.origin !== "null";
}

/** An object URL for this device's copy of the photo, or null when this device has none. */
export async function readLocalPhoto(path: string): Promise<string | null> {
  try {
    if (!usable()) return null;
    const cache = await caches.open(CACHE_NAME);
    const hit = await cache.match(cacheKey(path));
    if (!hit) return null;
    return URL.createObjectURL(await hit.blob());
  } catch {
    return null;
  }
}

/**
 * THE picture address for a chat photo, for its tile and for the small picture on a reply.
 *
 * Owner bug list 28 Nov, item 13: a chat photo jumped and flashed "as if it just landed again". Every chat update
 * refreshes the messages, the tile asked for its picture again, and each ask made a NEW address for the same picture
 * (a new object URL, or a new 5-minute link), so the picture was drawn again. Now the address a photo was first shown
 * with is handed back for the rest of the session: a 5-minute link for 4 minutes, this device's copy for good.
 * `sign` is the server's 5-minute link (passed in, so this file imports nothing).
 */
const shown = new Map<string, { url: string; until: number }>();
const LINK_REUSE_MS = 4 * 60_000;

export async function chatPhotoUrl(
  path: string,
  expired: boolean,
  sign: (path: string) => Promise<string | null>,
): Promise<{ url: string | null; gone: boolean }> {
  const hit = shown.get(path);
  if (hit && hit.until > Date.now()) return { url: hit.url, gone: false };
  const local = await readLocalPhoto(path);
  if (local) {
    shown.set(path, { url: local, until: Number.POSITIVE_INFINITY });
    return { url: local, gone: false };
  }
  if (expired) return { url: null, gone: true };
  const url = await sign(path);
  if (url) {
    shown.set(path, { url, until: Date.now() + LINK_REUSE_MS });
    void keepPhotoOnDevice(path, url);
  }
  return { url, gone: false };
}

/** Fetch the photo once from its short-lived link and keep it on this device. Never throws. */
export async function keepPhotoOnDevice(path: string, url: string): Promise<void> {
  try {
    if (!usable() || url.startsWith("data:")) return;
    const cache = await caches.open(CACHE_NAME);
    if (await cache.match(cacheKey(path))) return;
    const res = await fetch(url);
    if (!res.ok) return;
    await cache.put(cacheKey(path), res);
    // Ask the browser not to evict it (best effort; the app's WebView usually grants it).
    void navigator.storage?.persist?.().catch(() => undefined);
  } catch {
    /* no local copy — nothing to show the member */
  }
}

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

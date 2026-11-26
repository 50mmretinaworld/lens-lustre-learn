/**
 * "SHARE MY HONOUR" — the Instagram-ready image, drawn ON THE DEVICE (approved
 * design, Part 5). No new dependency: a <canvas>.
 *
 *   ┌────────────────────┐   post  1080 × 1350 (4:5)
 *   │   Featured photo   │   story 1080 × 1920 (9:16)
 *   │   (cover-cropped)  │
 *   ├────────────────────┤
 *   │ ✔ Honoured as Premium Member
 *   │ Neil Basu ✔
 *   │ 50mmretina.com/neil.basu        50mm Retina World
 *   └────────────────────┘
 *
 * THE PHOTO MUST NOT TAINT THE CANVAS. Photos live on the media CDN (another
 * origin). Drawing a cross-origin <img> without CORS taints the canvas and
 * toBlob() then throws a SecurityError. So the photo is FETCHED with
 * mode:"cors" and decoded from the blob (same recipe as photoCreditSave.ts):
 * a blob is same-origin, so the canvas stays clean. If the host refuses CORS
 * (or the photo is gone) this throws HonourImageError and the caller shows a
 * plain toast — never a broken or blank image.
 */
import { supabase } from "@/integrations/supabase/client";
import { memberPhotoSrc } from "@/lib/photoProtection";
import { isNativeCapacitorApp } from "@/lib/native/authDeepLink";
import { saveBlob } from "@/lib/saveFile";

export type HonourSize = "post" | "story";

export const HONOUR_SIZES: Record<HonourSize, { width: number; height: number; band: number }> = {
  post: { width: 1080, height: 1350, band: 300 },
  story: { width: 1080, height: 1920, band: 420 },
};

export const HONOUR_LINE = "Honoured as Premium Member";
export const HONOUR_BRAND = "50mm Retina World";
export const HONOUR_SITE = "50mmretina.com";
export const HONOUR_IMAGE_FAILED = "Your honour image could not be made — your photo did not load. Please try again in a moment.";

export class HonourImageError extends Error {}

const BG = "#0B0F19";
const TICK_BLUE = "#1D9BF0";
const ACCENT = "#5AB8F5";
const MUTED = "#94A3B8";
const FG = "#F8FAFC";
const FONT = `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`;
// The same two paths as VerifiedBadge.tsx (viewBox 24).
const TICK_STAR = "M12 0l2.37 3.15L18 2.1l.9 3.9 4 .45-2.1 3.45L23.1 13.5l-3.6 1.8.15 4.05-3.9-.75L12 21.75 8.25 18.6l-3.9.75.15-4.05L.9 13.5 3.2 9.9 1.1 6.45l4-.45L6 2.1l3.63 1.05L12 0z";
const TICK_CHECK = "M9.5 12.5l2 2 4-4.5";

/** "50mmretina.com/neil.basu" — just the site when the member has no handle. */
export function honourAddress(handle: string | null | undefined): string {
  const h = (handle ?? "").trim().replace(/^@/, "");
  return h ? `${HONOUR_SITE}/${h}` : HONOUR_SITE;
}

export function honourFileName(handle: string | null | undefined, size: HonourSize): string {
  const h = (handle ?? "").trim().replace(/[^A-Za-z0-9._-]+/g, "") || "member";
  return `50mm-premium-member-${h}-${size}.jpg`;
}

/**
 * The photo the image uses: the member's Featured photo, else the card photo
 * get_premium_members() gives (which is itself Featured-else-most-liked).
 * null when there is none (or SQL 6000 is not on this database).
 */
export async function resolveHonourPhoto(userId: string): Promise<string | null> {
  try {
    const fp = await supabase.from("premium_featured_posts" as never).select("post_id").eq("user_id", userId).maybeSingle();
    const postId = (fp.data as { post_id?: string } | null)?.post_id;
    if (!fp.error && postId) {
      const { data } = await supabase.from("posts").select("image_url, image_urls").eq("id", postId).maybeSingle();
      const row = data as { image_url?: string | null; image_urls?: string[] | null } | null;
      const url = row?.image_url || row?.image_urls?.[0];
      if (url) return url;
    }
    const { data, error } = await supabase.rpc("get_premium_members" as never, { _limit: 200 } as never);
    if (error || !Array.isArray(data)) return null;
    const me = (data as { user_id?: string; photo_url?: string | null }[]).find((r) => r.user_id === userId);
    return me?.photo_url ?? null;
  } catch {
    return null;
  }
}

type Decoded = { img: CanvasImageSource; width: number; height: number; close: () => void };

async function loadPhoto(url: string): Promise<Decoded> {
  const src = memberPhotoSrc(url, 1080) ?? url;
  let blob: Blob;
  try {
    const res = await fetch(src, { mode: "cors", credentials: "omit" });
    if (!res.ok) throw new Error(`photo ${res.status}`);
    blob = await res.blob();
  } catch (e) {
    throw new HonourImageError(e instanceof Error ? e.message : "photo fetch failed");
  }
  try {
    if (typeof createImageBitmap === "function") {
      const b = await createImageBitmap(blob);
      return { img: b, width: b.width, height: b.height, close: () => b.close() };
    }
    const u = URL.createObjectURL(blob);
    try {
      const el = new Image();
      el.src = u;
      await el.decode();
      return { img: el, width: el.naturalWidth, height: el.naturalHeight, close: () => {} };
    } finally {
      URL.revokeObjectURL(u);
    }
  } catch (e) {
    throw new HonourImageError(e instanceof Error ? e.message : "photo decode failed");
  }
}

function drawTick(ctx: CanvasRenderingContext2D, x: number, y: number, size: number): void {
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(size / 24, size / 24);
  ctx.fillStyle = TICK_BLUE;
  ctx.fill(new Path2D(TICK_STAR));
  ctx.strokeStyle = "#FFFFFF";
  ctx.lineWidth = 1.8;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.stroke(new Path2D(TICK_CHECK));
  ctx.restore();
}

/** The largest font size (≤ start, ≥ min) at which `text` fits; cut with "…" if even min does not. */
function fitText(ctx: CanvasRenderingContext2D, text: string, weight: number, start: number, min: number, maxW: number): { text: string; px: number } {
  for (let px = start; px >= min; px -= 2) {
    ctx.font = `${weight} ${px}px ${FONT}`;
    if (ctx.measureText(text).width <= maxW) return { text, px };
  }
  ctx.font = `${weight} ${min}px ${FONT}`;
  let t = text;
  while (t.length > 1 && ctx.measureText(`${t}…`).width > maxW) t = t.slice(0, -1);
  return { text: `${t}…`, px: min };
}

/** Cover-crop the photo into the top area (centred, never stretched). */
function drawCover(ctx: CanvasRenderingContext2D, p: Decoded, w: number, h: number): void {
  const scale = Math.max(w / p.width, h / p.height);
  const sw = w / scale;
  const sh = h / scale;
  ctx.drawImage(p.img, (p.width - sw) / 2, (p.height - sh) / 2, sw, sh, 0, 0, w, h);
}

export interface HonourImageInput {
  photoUrl: string;
  name: string;
  handle: string | null | undefined;
}

/** Draw both sizes from ONE photo download. Throws HonourImageError when the photo cannot be drawn. */
export async function drawHonourImages(input: HonourImageInput): Promise<Record<HonourSize, Blob>> {
  const photo = await loadPhoto(input.photoUrl);
  try {
    const [post, story] = [await paint(input, photo, "post"), await paint(input, photo, "story")];
    return { post, story };
  } finally {
    photo.close();
  }
}

async function paint(input: HonourImageInput, photo: Decoded, size: HonourSize): Promise<Blob> {
  const { width: W, height: H, band } = HONOUR_SIZES[size];
  const canvas = document.createElement("canvas");
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new HonourImageError("Canvas 2D context unavailable");

  ctx.fillStyle = BG;
  ctx.fillRect(0, 0, W, H);
  drawCover(ctx, photo, W, H - band);
  ctx.textBaseline = "alphabetic";

  const pad = 64;
  const maxW = W - pad * 2;
  const top = H - band;
  const address = honourAddress(input.handle);

  if (size === "post") {
    // ✔ Honoured as Premium Member
    drawTick(ctx, pad, top + 44, 40);
    ctx.font = `600 34px ${FONT}`;
    ctx.fillStyle = ACCENT;
    ctx.textAlign = "left";
    ctx.fillText(HONOUR_LINE, pad + 54, top + 76);
    // Name ✔
    const nm = fitText(ctx, input.name, 700, 72, 44, maxW - 76);
    ctx.fillStyle = FG;
    ctx.fillText(nm.text, pad, top + 170);
    const nw = ctx.measureText(nm.text).width;
    drawTick(ctx, pad + nw + 16, top + 170 - nm.px * 0.78, nm.px * 0.8);
    // 50mmretina.com/handle ··· 50mm Retina World
    ctx.font = `700 34px ${FONT}`;
    const bw = ctx.measureText(HONOUR_BRAND).width;
    ctx.fillStyle = FG;
    ctx.textAlign = "right";
    ctx.fillText(HONOUR_BRAND, W - pad, top + 250);
    const ad = fitText(ctx, address, 400, 30, 22, maxW - bw - 32);
    ctx.fillStyle = MUTED;
    ctx.textAlign = "left";
    ctx.fillText(ad.text, pad, top + 250);
  } else {
    const cx = W / 2;
    // Name ✔ (centred as one unit)
    const nm = fitText(ctx, input.name, 700, 76, 44, maxW - 80);
    const nw = ctx.measureText(nm.text).width;
    const tick = nm.px * 0.8;
    const startX = cx - (nw + 16 + tick) / 2;
    ctx.fillStyle = FG;
    ctx.textAlign = "left";
    ctx.fillText(nm.text, startX, top + 130);
    drawTick(ctx, startX + nw + 16, top + 130 - nm.px * 0.78, tick);
    // ✔ Honoured as Premium Member
    ctx.font = `600 38px ${FONT}`;
    const lw = ctx.measureText(HONOUR_LINE).width;
    drawTick(ctx, cx - (lw + 52) / 2, top + 178, 40);
    ctx.fillStyle = ACCENT;
    ctx.fillText(HONOUR_LINE, cx - (lw + 52) / 2 + 52, top + 210);
    ctx.textAlign = "center";
    const ad = fitText(ctx, address, 400, 34, 24, maxW);
    ctx.fillStyle = MUTED;
    ctx.fillText(ad.text, cx, top + 290);
    ctx.font = `700 38px ${FONT}`;
    ctx.fillStyle = FG;
    ctx.fillText(HONOUR_BRAND, cx, top + 360);
  }

  try {
    return await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("toBlob returned nothing"))), "image/jpeg", 0.92));
  } catch (e) {
    // SecurityError = a tainted canvas; anything else = canvas limits on this device.
    throw new HonourImageError(e instanceof Error ? e.message : "canvas export failed");
  } finally {
    canvas.width = 0;
    canvas.height = 0;
  }
}

/**
 * Hand the image over: the app → the native share sheet (saveBlob: Filesystem +
 * Share, "Save or share"); a phone browser → Web Share with the file; anything
 * else → a download. A member closing the share sheet is not an error.
 */
export async function shareHonourImage(blob: Blob, fileName: string): Promise<"shared" | "saved" | "cancelled"> {
  if (isNativeCapacitorApp()) {
    await saveBlob(blob, fileName);
    return "shared";
  }
  const file = typeof File === "function" ? new File([blob], fileName, { type: blob.type || "image/jpeg" }) : null;
  const nav = typeof navigator !== "undefined" ? navigator : null;
  if (file && nav?.canShare?.({ files: [file] }) && typeof nav.share === "function") {
    try {
      await nav.share({ files: [file], title: HONOUR_LINE });
      return "shared";
    } catch (e) {
      if (e instanceof Error && e.name === "AbortError") return "cancelled";
      // Any other refusal (e.g. no user gesture left): fall through to a download.
    }
  }
  await saveBlob(blob, fileName);
  return "saved";
}

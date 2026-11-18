/**
 * Messages · one photo, ready for the private bucket.
 * The browser re-draws the picture onto a canvas and saves it as WebP: that drops every
 * trace of location / camera data (EXIF) and fixes the type. Longest side 1600 px, under
 * 5 MB (the bucket's own limit). The file goes into the member's own folder
 * <uid>/<random>.webp — the only place storage lets them write. The server door
 * (message_send_photo) then checks the file exists, is theirs, is the right type and size,
 * and has not been used before.
 */
import { supabase } from "@/integrations/supabase/client";
import { safeRandomUUID } from "@/lib/safeUuid";

export const MAX_PHOTO_SIDE = 1600;
const MAX_BYTES = 5_000_000;

export interface UploadedPhoto { path: string; width: number; height: number }

function toBlob(canvas: HTMLCanvasElement, quality: number): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob(resolve, "image/webp", quality));
}

/** Pure sizing rule (tested): keep the aspect ratio, never upscale. */
export function fitWithin(width: number, height: number, side = MAX_PHOTO_SIDE): { width: number; height: number } {
  const longest = Math.max(width, height);
  if (longest <= side || longest <= 0) return { width: Math.max(1, Math.round(width)), height: Math.max(1, Math.round(height)) };
  const k = side / longest;
  return { width: Math.max(1, Math.round(width * k)), height: Math.max(1, Math.round(height * k)) };
}

export async function prepareAndUploadPhoto(file: File, userId: string): Promise<UploadedPhoto> {
  if (!/^image\//.test(file.type)) throw new Error("not-an-image");
  const bitmap = await createImageBitmap(file);
  const { width, height } = fitWithin(bitmap.width, bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("no-canvas");
  ctx.drawImage(bitmap, 0, 0, width, height);
  bitmap.close?.();
  let blob: Blob | null = null;
  for (const q of [0.86, 0.72, 0.58]) {
    blob = await toBlob(canvas, q);
    if (blob && blob.size <= MAX_BYTES) break;
  }
  if (!blob || blob.size > MAX_BYTES) throw new Error("photo-too-big");
  const path = `${userId}/${safeRandomUUID()}.webp`;
  const { error } = await supabase.storage.from("message-photos").upload(path, blob, { contentType: "image/webp", upsert: false });
  if (error) throw new Error("upload-failed");
  return { path, width, height };
}

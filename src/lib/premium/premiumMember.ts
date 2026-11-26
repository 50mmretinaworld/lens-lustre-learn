/** What a Premium Member card shows, worked out once (PremiumMemberCard reads these). */
import { memberPhotoSrc } from "@/lib/photoProtection";
import { photoSetMarker } from "@/lib/imageLadder";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "Nov 2026" from the honour date (UTC); null when there is none or it is not a date. */
export function honouredLabel(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** The card's photo: a set photo's 600 copy; an old photo's stored thumbnail, else the photo itself. */
export function premiumPhotoSrc(m: { photo_url: string | null; thumb_url: string | null }): string | null {
  const p = m.photo_url;
  if (p && photoSetMarker(p)) return memberPhotoSrc(p, 600);
  return m.thumb_url ?? p;
}

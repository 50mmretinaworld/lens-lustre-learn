/** Messages · small display rules: clock text, day labels, and grouping of a chat into bubbles. Pure, tested. */
import type { ThreadMessage } from "./api";

const GROUP_GAP_MS = 5 * 60_000;

/** "14:32" in the member's own timezone and locale. */
export function clockText(iso: string, locale?: string): string {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return "";
  return d.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
}

const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();

/** "Today", "Yesterday", else "Wed, 12 Nov" (adds the year when it is not this year). */
export function dayLabel(iso: string, now: Date = new Date(), locale?: string): string {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return "";
  const diffDays = Math.round((startOfDay(now) - startOfDay(d)) / 86_400_000);
  if (diffDays === 0) return "Today";
  if (diffDays === 1) return "Yesterday";
  return d.toLocaleDateString(locale, { weekday: "short", day: "numeric", month: "short", ...(d.getFullYear() !== now.getFullYear() ? { year: "numeric" } : {}) });
}

/**
 * Meta-style last-seen line for a person who is not online right now:
 * "Active 5 m ago" · "Active 3 h ago" · "Active yesterday" · "Active 4 d ago"; nothing after a week (or when unknown).
 */
export function activeAgoText(iso: string | null | undefined, now: Date = new Date()): string | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  const min = Math.floor((now.getTime() - t) / 60000);
  if (min < 1) return "Active just now";
  if (min < 60) return `Active ${min} m ago`;
  const h = Math.floor(min / 60);
  if (h < 24) return `Active ${h} h ago`;
  const d = Math.floor(h / 24);
  if (d === 1) return "Active yesterday";
  if (d <= 7) return `Active ${d} d ago`;
  return null;
}

export type ChatItem =
  | { type: "day"; key: string; label: string }
  | { type: "msg"; key: string; m: ThreadMessage; first: boolean; last: boolean };

/**
 * Oldest-first messages → day chips and bubbles. A bubble is "first" / "last" in its run: same sender, same day,
 * less than five minutes apart. The tail (time, rounded corner) belongs to the last of a run.
 */
export function groupChat(messages: ThreadMessage[], now: Date = new Date()): ChatItem[] {
  const out: ChatItem[] = [];
  let prev: ThreadMessage | null = null;
  messages.forEach((m, i) => {
    const day = startOfDay(new Date(m.createdAt));
    const prevDay = prev ? startOfDay(new Date(prev.createdAt)) : null;
    if (prevDay === null || day !== prevDay) out.push({ type: "day", key: `d-${day}`, label: dayLabel(m.createdAt, now) });
    const near = (a: ThreadMessage, b: ThreadMessage) =>
      a.senderId === b.senderId && a.photos.length === 0 && b.photos.length === 0 && startOfDay(new Date(a.createdAt)) === startOfDay(new Date(b.createdAt))
      && Math.abs(new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()) < GROUP_GAP_MS;
    const next = messages[i + 1];
    out.push({ type: "msg", key: `m-${m.id}`, m, first: !prev || !near(prev, m), last: !next || !near(m, next) });
    prev = m;
  });
  return out;
}

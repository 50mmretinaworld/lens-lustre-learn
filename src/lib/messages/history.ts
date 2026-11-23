/**
 * Messages · ONE ordered list of everything a chat screen has loaded (oldest first).
 *
 * Owner 23 Nov: "msg sent 200 but showing only few, on scrolling it is not showing too". The chat used to keep
 * the newest page (refreshed every 30 s and after every send) and, apart from it, the older pages loaded by
 * scrolling up. When new messages pushed earlier ones out of the newest page, those fell into a HOLE between
 * the two lists — and if the start of the chat had already been reached, scrolling up never asked again.
 *
 * Now every page is merged into one list. A fresh newest page that does not reach back to what the screen
 * already holds reports the hole (`gapBefore`), and the screen loads pages before it until the hole is closed.
 * Inside the range a fresh page covers, it is the truth (a removed message leaves the screen).
 */
export interface HasId { id: number }

/** Both lists oldest first. `page` is the server's newest page; `full` = it came back with a whole page of rows. */
export function mergeNewest<T extends HasId>(history: T[], page: T[], full: boolean): { merged: T[]; gapBefore: number | null } {
  if (page.length === 0) return { merged: full ? history : [], gapBefore: null };
  if (history.length === 0) return { merged: page, gapBefore: null };
  const pMin = page[0].id;
  const before = history.filter((m) => m.id < pMin);
  const merged = [...before, ...page];
  // A whole page whose oldest row is newer than everything the screen held before it → rows may be missing between.
  const heldMax = before.length ? before[before.length - 1].id : null;
  const overlapped = history.some((m) => m.id >= pMin);
  const gapBefore = full && heldMax !== null && !overlapped ? pMin : null;
  return { merged, gapBefore };
}

/** An older page (oldest first) merged in front / into the list; duplicates dropped, order kept. */
export function mergeOlder<T extends HasId>(history: T[], older: T[]): T[] {
  if (older.length === 0) return history;
  const seen = new Set(history.map((m) => m.id));
  return [...older.filter((m) => !seen.has(m.id)), ...history].sort((a, b) => a.id - b.id);
}

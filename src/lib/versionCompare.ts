/**
 * App version numbers, compared as numbers — "1.2.10" is newer than "1.2.9".
 * Pure, no imports: Admin → Users (app version per member + the versions card)
 * and any later "is this build old?" check use this one copy.
 *
 * Rules: split on "." (a "-beta"/"+build" tail is ignored for the order), each
 * part compared as a whole number, a missing part counts as 0 ("1.2" = "1.2.0").
 * A part that is not a number sorts below any number. Empty / null sorts lowest.
 */

const parts = (v: string): number[] =>
  v.trim().split(/[-+]/)[0].split(".").map((p) => (/^\d+$/.test(p) ? Number(p) : -1));

/** < 0 when a is older than b, 0 when the same, > 0 when a is newer. */
export function compareVersions(a: string | null | undefined, b: string | null | undefined): number {
  const ea = !a || !a.trim();
  const eb = !b || !b.trim();
  if (ea || eb) return ea && eb ? 0 : ea ? -1 : 1;
  const pa = parts(a);
  const pb = parts(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

/** The newest version in a list (null when the list has none). */
export function newestVersion(versions: (string | null | undefined)[]): string | null {
  let best: string | null = null;
  for (const v of versions) if (v && v.trim() && (best === null || compareVersions(v, best) > 0)) best = v;
  return best;
}

/** Versions newest first; equal ones keep their order. */
export const sortVersionsDesc = <T>(rows: T[], get: (r: T) => string | null | undefined): T[] =>
  [...rows].sort((x, y) => compareVersions(get(y), get(x)));

/** True when `v` is older than the newest seen — the amber "old" mark. */
export const isOldVersion = (v: string | null | undefined, newest: string | null | undefined): boolean =>
  !!v && !!newest && compareVersions(v, newest) < 0;

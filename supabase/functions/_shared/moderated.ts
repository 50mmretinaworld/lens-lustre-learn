/**
 * B · ONE RULE FOR "NOT OFFERED TO SEARCH": a banned or suspended member.
 *
 * seo-route-metadata already marks such a member's profile and posts noindex
 * ("profile-moderated", "post-author-moderated"), but the sitemap listed them
 * anyway — Search Console 25 Nov 2026 found /member.db9be324 in sitemap.xml with
 * a noindex head (a sitemap that contradicts the page). Both now read the rule
 * from here, so they cannot drift apart again.
 */

// deno-lint-ignore no-explicit-any
type Db = { from: (table: string) => any };

const MODERATED = "is_banned.eq.true,is_suspended.eq.true";

/** The ids in `ids` whose member is banned or suspended (the head's per-page check). */
export async function moderatedIds(db: Db, ids: string[]): Promise<string[]> {
  if (!ids.length) return [];
  const { data } = await db.from("profiles_public_data").select("id, is_banned, is_suspended").in("id", ids);
  // deno-lint-ignore no-explicit-any
  return ((data ?? []) as any[]).filter((p) => p.is_banned || p.is_suspended).map((p) => p.id);
}

/** Every banned or suspended member at once (the sitemap's whole-list check; a short list). */
export async function moderatedSet(db: Db): Promise<Set<string>> {
  const { data } = await db.from("profiles_public_data").select("id").or(MODERATED).limit(10000);
  // deno-lint-ignore no-explicit-any
  return new Set(((data ?? []) as any[]).map((p) => p.id as string));
}

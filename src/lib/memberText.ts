/**
 * MEMBER TEXT — the ONE rule for what a member wrote (posts, comments, story
 * captions) and the members tagged in it.
 *
 * ROOT RULE (Owner, 18 Nov 2026: "if I use a name in 100 places, it must come
 * from one source, like Meta"):
 *   A tag is IDENTIFIED by the member's id. Its NAME and LINK always come from
 *   that member's profile — the one source, src/lib/profileMapCache.ts — at the
 *   moment it is shown. A rename shows everywhere at once, old comments too.
 *
 * Stored form, unchanged ON PURPOSE: `@[Name](member-id)`, group tags
 * `@[@all](all)` / `@[@followers](followers)`. Every app already installed on
 * members' phones (≤ 1.2.50) reads exactly this form and nothing else; storing
 * an id-only form today would put raw codes on all those phones. The `Name` in
 * the stored form is therefore ONLY a fallback — for a member whose profile no
 * longer exists, and for the instant before the profile arrives — never the
 * source.
 *
 * Who shows what:
 *   · Full text with links  → <RichContentRenderer content=… />
 *   · Previews, lists, labels → <MemberText text=… />  (plain, same names)
 *   Both read names through useMemberNames() below — no screen reads a name
 *   out of the text. Guarded by src/__tests__/memberTextOneRule.test.ts.
 *   memberTextPlain() is for matching / search only (no profile lookup).
 */

/** The stored tag. Group 1 = name copied at typing time (fallback only), group 2 = member id or all/followers. */
export const MENTION_SOURCE = String.raw`@\[([^\]]+)\]\(([^)]+)\)`;
const MENTION = new RegExp(MENTION_SOURCE, "g");

export const GROUP_TAGS = new Set(["all", "followers"]);

export type MemberTextPart =
  | { kind: "text"; text: string }
  | { kind: "member"; id: string; storedName: string }
  | { kind: "group"; group: string };

/** Split stored text into plain runs and tags. Pure. */
export function parseMemberText(content: string | null | undefined): MemberTextPart[] {
  if (!content) return [];
  const parts: MemberTextPart[] = [];
  let last = 0;
  for (const m of content.matchAll(MENTION)) {
    const at = m.index ?? 0;
    if (at > last) parts.push({ kind: "text", text: content.slice(last, at) });
    const ref = m[2];
    parts.push(GROUP_TAGS.has(ref) ? { kind: "group", group: ref } : { kind: "member", id: ref, storedName: m[1] });
    last = at + m[0].length;
  }
  if (last < content.length) parts.push({ kind: "text", text: content.slice(last) });
  return parts;
}

/** Member ids tagged in a text (deduped). */
export function taggedMemberIds(content: string | null | undefined): string[] {
  return [...new Set(parseMemberText(content).flatMap((p) => (p.kind === "member" ? [p.id] : [])))];
}

/** A tagged member as the profile says right now. `null` name = no such profile (fall back to the stored name, no link). */
export interface MemberIdentity {
  name: string | null;
  handle: string | null;
}

/** The name a tag shows: the profile's, else (member gone / not loaded yet) the copy in the text. */
export function tagName(part: Extract<MemberTextPart, { kind: "member" }>, who: MemberIdentity | undefined): string {
  const fromProfile = who?.name?.trim();
  return fromProfile || part.storedName.replace(/^@+/, "");
}

/** Plain text with tags as "@Name" (names from `names`, the profile source). */
export function memberTextResolved(content: string | null | undefined, names: ReadonlyMap<string, MemberIdentity>): string {
  return parseMemberText(content)
    .map((p) => (p.kind === "text" ? p.text : p.kind === "group" ? `@${p.group}` : `@${tagName(p, names.get(p.id))}`))
    .join("");
}

/** Fold whitespace and cut to `max` characters with "…". */
export function cutText(text: string, max: number): string {
  const one = text.replace(/\s+/g, " ").trim();
  return one.length <= max ? one : `${one.slice(0, max - 1).trimEnd()}…`;
}

/**
 * MATCHING / SEARCH ONLY — tags as "@<name copied in the text>", no profile
 * lookup. Never for display (the ratchet refuses it in .tsx).
 */
export function memberTextPlain(content: string | null | undefined): string {
  return memberTextResolved(content, new Map());
}

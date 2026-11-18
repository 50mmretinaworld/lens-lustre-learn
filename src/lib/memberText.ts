/**
 * MEMBER TEXT — the ONE rule for showing what a member wrote (posts, comments,
 * story captions) anywhere a full renderer does not fit.
 *
 * A mention is STORED as `@[Name](member-id)` (and a group tag as
 * `@[@all](all)` / `@[@followers](followers)`). Nobody may ever SEE that form.
 *   · Full text with links → <RichContentRenderer content=… /> (the one renderer).
 *   · Short previews, lists, labels, notifications → memberTextPlain() below.
 *
 * Owner, 18 Nov 2026 (story screenshot "@[Sri V R Narayanasw](83f6…)"): the
 * story comments printed the stored form because they skipped the renderer.
 * src/__tests__/memberTextOneRule.test.ts fails any screen that prints a
 * `.content` / `.caption` straight into the page again.
 */

/** Same token the renderer reads (RichContentRenderer TOKEN_REGEX, mention half). */
const MENTION = /@\[([^\]]+)\]\(([^)]+)\)/g;

/** "@[Neil Basu](uuid) great" → "@Neil Basu great"; "@[@all](all)" → "@all". */
export function memberTextPlain(content: string | null | undefined): string {
  if (!content) return "";
  return content.replace(MENTION, (_m, name: string) => `@${name.replace(/^@+/, "")}`);
}

/** memberTextPlain + whitespace folded + cut to `max` characters with "…". */
export function memberTextPreview(content: string | null | undefined, max: number): string {
  const plain = memberTextPlain(content).replace(/\s+/g, " ").trim();
  return plain.length <= max ? plain : `${plain.slice(0, max - 1).trimEnd()}…`;
}

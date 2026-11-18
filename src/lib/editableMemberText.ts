/**
 * EDITING STORED MEMBER TEXT — the one rule for every box that opens text a
 * member wrote earlier (post caption edit, scheduled-post edit, resumed draft).
 *
 * Owner, 18 Nov 2026: "no @[...] text anywhere, from the root". A member must
 * never see or type the stored form @[Name](id). So an editor opens the text as
 * "@Name" (the NAME from the member's profile — the one source, memberText.ts)
 * together with the PICKS (name → member id) that turn it back into tags on
 * save, the same machinery the composer uses (captionMentions.ts).
 *
 * Never a wrong tag: if one visible name would stand for two different
 * members, neither is converted back — both stay plain "@Name" text.
 */
import { fetchProfileMap } from "@/lib/profileMapCache";
import { MENTION_SOURCE, taggedMemberIds, tagName } from "@/lib/memberText";
import { isGroupMentionId } from "@/lib/groupMentions";
import { applyCaptionMentions, type PickedMention } from "@/lib/captionMentions";

export interface EditableText {
  /** What the box shows: tags read "@Name"; never the stored markup. */
  text: string;
  /** Hand to storedFromEditable() on save. */
  picks: PickedMention[];
}

export async function loadEditableText(stored: string | null | undefined): Promise<EditableText> {
  const source = stored ?? "";
  let names: Awaited<ReturnType<typeof fetchProfileMap>> = new Map();
  const ids = taggedMemberIds(source);
  if (ids.length) {
    try { names = await fetchProfileMap(ids); } catch { /* the names typed in the text are used */ }
  }
  const byDisplay = new Map<string, string | null>(); // null = ambiguous
  const text = source.replace(new RegExp(MENTION_SOURCE, "g"), (_m, name: string, id: string) => {
    const display = isGroupMentionId(id) ? id : tagName(name, names.get(id));
    const seen = byDisplay.get(display);
    byDisplay.set(display, seen === undefined || seen === id ? id : null);
    return `@${display}`;
  });
  const picks: PickedMention[] = [];
  byDisplay.forEach((id, display) => { if (id) picks.push({ display, id }); });
  return { text, picks };
}

/** Visible text → stored markup (names that were not touched become tags again). */
export const storedFromEditable = (text: string, picks: PickedMention[]): string => applyCaptionMentions(text, picks);

import { useCallback, useState } from "react";
import { displayName } from "@/lib/displayName";

/**
 * ONE REPLY FLOW (Owner, 10 Nov 2026: "when replying it is coming another box
 * while Meta shows simple box").
 *
 * Tapping Reply no longer opens a second box inside the comment. It names the
 * comment being answered; the ONE comment box at the bottom shows
 * "Replying to <name> · <first words> ×", starts with the name as a mention,
 * and the answered comment is softly highlighted. Every comment surface (post
 * sheet, post page, photo viewer) wires the same two halves with this hook.
 */
export interface ReplyTarget {
  /** The comment being answered — becomes the reply's parent_id. */
  id: string;
  /** Its author, for the mention the box starts with. */
  userId: string;
  name: string;
  /** Its first words, shown faintly after the name so it is clear WHICH comment. */
  preview: string;
}

/** How many characters of the answered comment the box shows. */
export const REPLY_PREVIEW_MAX = 40;

/**
 * `preview` is the answered comment's STORED text; the composer shows it through
 * <MemberText max={REPLY_PREVIEW_MAX}>, so a tag in it reads the member's
 * current profile name (src/lib/memberText.ts root rule).
 */
export function toReplyTarget(c: { id: string; user_id: string; author_name: string | null; content: string }): ReplyTarget {
  return { id: c.id, userId: c.user_id, name: displayName(c.author_name), preview: c.content };
}

/** The shared state: who is being answered, if anyone. */
export function useReplyTarget() {
  const [target, setTarget] = useState<ReplyTarget | null>(null);
  const start = useCallback((t: ReplyTarget) => setTarget(t), []);
  const cancel = useCallback(() => setTarget(null), []);
  return { target, start, cancel };
}

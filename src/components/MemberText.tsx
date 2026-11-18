/**
 * Member-written text as PLAIN text — previews, lists, labels, notification
 * quotes. Tags read "@Name" with the name from the member's profile (the one
 * source, useMemberNames); never the stored @[Name](id). For the full text with
 * links use <RichContentRenderer>. Rule: src/lib/memberText.ts.
 */
import { cutText, memberTextResolved, taggedMemberIds } from "@/lib/memberText";
import { useMemberNames } from "@/hooks/profile/useMemberNames";

export default function MemberText({ text, max }: { text: string | null | undefined; max?: number }) {
  const names = useMemberNames(taggedMemberIds(text));
  const plain = memberTextResolved(text, names);
  return <>{max ? cutText(plain, max) : plain}</>;
}

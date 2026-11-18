/**
 * The post page's title / share-preview description. The description is the
 * caption as plain text: a tag reads "@Name" with the name from the member's
 * profile (src/lib/memberText.ts, the one rule) — never the stored @[Name](id),
 * which would show in a shared link's preview.
 */
import PageSEO from "@/components/PageSEO";
import { useMemberNames } from "@/hooks/profile/useMemberNames";
import { cutText, memberTextResolved, taggedMemberIds } from "@/lib/memberText";

export default function PostPageSEO({ title, content, ogImage }: { title: string; content: string | null | undefined; ogImage?: string }) {
  const names = useMemberNames(taggedMemberIds(content));
  const description = cutText(memberTextResolved(content, names), 160) || "A post on 50mm Retina World";
  return <PageSEO title={title} description={description} ogImage={ogImage} ogType="article" />;
}

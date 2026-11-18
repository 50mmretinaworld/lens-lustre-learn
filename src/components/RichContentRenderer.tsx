import { Fragment } from "react";
import { Link } from "react-router-dom";
import { memberPath } from "@/lib/urlHelpers";
import { useMemberNames } from "@/hooks/profile/useMemberNames";
import { MENTION_SOURCE, tagName, taggedMemberIds } from "@/lib/memberText";
import { sanitizeUserContent } from "@/lib/htmlSanitizer";
import { isGroupMentionId } from "@/lib/groupMentions";
import { HASHTAG_TOKEN_SOURCE, MAX_TAGS_PER_POST, hashtagPath, sameTagKey } from "@/lib/hashtags/hashtagRule";

/**
 * Renders text content with:
 * - @[Name](userId) → clickable profile link
 * - #hashtag → clickable hashtag link
 */

interface Props {
  content: string;
  className?: string;
}

// Matches @[Display Name](uuid) or #tag — the tag part is THE hashtag rule
// (src/lib/hashtags/hashtagRule.ts, mirrored from the database), so a tag in
// any language is a link, and a link is always a tag the hashtag page knows.
const TOKEN_REGEX = new RegExp(MENTION_SOURCE + "|" + HASHTAG_TOKEN_SOURCE, "gu");

const RichContentRenderer = ({ content, className = "" }: Props) => {
  /*
   * ROOT RULE (Owner 18 Nov 2026, src/lib/memberText.ts): a tag's NAME and LINK
   * come from the member's profile — the one source — never from the text.
   * Every tagged id in this block is resolved in ONE batched lookup. (Hook first:
   * it must run on every render, empty text included.)
   */
  const names = useMemberNames(taggedMemberIds(content));
  if (!content) return null;
  const safeContent = sanitizeUserContent(content);

  const parts: React.ReactNode[] = [];
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  const regex = new RegExp(TOKEN_REGEX.source, "gu");
  // The server counts the first 30 distinct tags of a post; a 31st stays text,
  // so no link ever opens a hashtag page this post is not on.
  const linkedTags = new Set<string>();

  while ((match = regex.exec(content)) !== null) {
    // Text before match
    if (match.index > lastIndex) {
      parts.push(<Fragment key={`t-${lastIndex}`}>{content.slice(lastIndex, match.index)}</Fragment>);
    }

    if (match[1] && match[2]) {
      /*
       * A tag: @[Name](id). The id says WHO; the profile says the name and the
       * link (useMemberNames). The name copied in the text is used only until the
       * profile arrives, or for a member who no longer exists — then as plain
       * text, never a link. @all / @followers: a tag, not a member, never a link.
       */
      const group = isGroupMentionId(match[2]);
      const who = group ? undefined : names.get(match[2]);
      const label = group
        ? `@${match[2]}`
        : tagName(match[1], who);
      const mentionHref = group ? null : memberPath(who?.full_name ? who.custom_url : null);
      parts.push(
        mentionHref ? (
          <Link
            key={`m-${match.index}`}
            to={mentionHref}
            data-member-tag={match[2]}
            className="text-primary font-semibold hover:underline"
          >
            {label}
          </Link>
        ) : (
          <span key={`m-${match.index}`} data-member-tag={group ? undefined : match[2]} className="text-primary font-semibold">
            {label}
          </span>
        )
      );
    } else if (match[3]) {
      // #hashtag
      const key = sameTagKey(match[3]);
      if (linkedTags.has(key) || linkedTags.size < MAX_TAGS_PER_POST) {
        linkedTags.add(key);
        parts.push(
          <Link
            key={`h-${match.index}`}
            to={hashtagPath(match[3])}
            className="text-primary font-medium hover:underline"
          >
            #{match[3]}
          </Link>
        );
      } else {
        parts.push(<Fragment key={`h-${match.index}`}>{match[0]}</Fragment>);
      }
    }

    lastIndex = match.index + match[0].length;
  }

  // Remaining text
  if (lastIndex < content.length) {
    parts.push(<Fragment key={`t-${lastIndex}`}>{content.slice(lastIndex)}</Fragment>);
  }

  return <span className={className}>{parts}</span>;
};

export default RichContentRenderer;

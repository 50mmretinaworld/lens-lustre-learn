/**
 * STORY CAPTION — two lines, then "more" (Owner 18 Nov 2026: "big write up …
 * full body covered up with text … show three lines and then see more, story is
 * losing its purpose").
 *
 * A story made from a post carries the post's WHOLE text (stories_v2:
 * CASE WHEN post_id … p.content). On the story it shows at most two lines,
 * without the trailing block of hashtags, on the dark fade at the bottom of the
 * story, so the photograph stays the story. "more" opens the full text, tags
 * included, in the story's own panel; the story waits while it is open.
 */
import { useLayoutEffect, useRef, useState } from "react";
import RichContentRenderer from "@/components/RichContentRenderer";
import { HASHTAG_TOKEN_SOURCE } from "@/lib/hashtags/hashtagRule";
import { useT } from "@/i18n/I18nContext";

/** The trailing run of hashtags (and the space around them) at the END of a text. */
const TRAILING_TAGS = new RegExp(String.raw`(?:\s*${HASHTAG_TOKEN_SOURCE})+\s*$`, "u");

/** The caption as the story shows it before "more": trailing hashtags dropped (unless that is all there is). */
export function storyCaptionShort(caption: string): string {
  const full = caption.trim();
  const short = full.replace(TRAILING_TAGS, "").trim();
  return short || full;
}

export default function StoryCaption({ caption, onMore }: { caption: string; onMore: () => void }) {
  const t = useT();
  const short = storyCaptionShort(caption);
  const ref = useRef<HTMLParagraphElement>(null);
  const [clipped, setClipped] = useState(false);

  useLayoutEffect(() => {
    const el = ref.current;
    setClipped(!!el && el.scrollHeight > el.clientHeight + 1);
  }, [short]);

  const hasMore = clipped || short !== caption.trim();

  return (
    <div data-testid="story-caption">
      <p ref={ref} className="line-clamp-2 whitespace-pre-line break-words text-[15px] font-medium leading-snug [text-shadow:0_1px_3px_rgba(0,0,0,0.7)]">
        <RichContentRenderer content={short} />
      </p>
      {hasMore && (
        <button type="button" onClick={onMore} data-testid="story-caption-more"
          className="tap-44 mt-0.5 text-sm font-semibold text-white/85 [text-shadow:0_1px_3px_rgba(0,0,0,0.7)]">
          {t("story.more", "more")}
        </button>
      )}
    </div>
  );
}

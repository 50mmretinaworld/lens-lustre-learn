/**
 * The photography phrases under the comment box (Owner 18 Nov 2026) — one row
 * that scrolls sideways; a tap hands the words to the box (the composer adds
 * them, never posts). Loaded LAZILY by CommentComposer: the phrases in seven
 * languages stay out of the entry bundle (P13), and the row appears the moment
 * the chunk and the admin's setting are in.
 */
import { useCommentSuggestions } from "@/hooks/core/useCommentSuggestions";

export default function CommentSuggestionChips({ onPick, disabled }: { onPick: (phrase: string) => void; disabled: boolean }) {
  const suggestions = useCommentSuggestions();
  if (suggestions.length === 0) return null;
  return (
    <div
      className="-mx-1 mb-1.5 flex w-full min-w-0 max-w-full gap-1.5 overflow-x-auto px-1 pb-0.5 [contain:inline-size] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      role="group"
      aria-label="Add a suggestion to your comment"
      data-testid="comment-suggestions"
    >
      {suggestions.map((phrase) => (
        <button
          key={phrase}
          type="button"
          onClick={() => onPick(phrase)}
          disabled={disabled}
          className="tap-44 h-8 shrink-0 whitespace-nowrap rounded-full border border-border bg-muted/40 px-3 text-[13px] font-medium text-foreground transition-colors hover:bg-muted active:scale-95 disabled:opacity-50 motion-reduce:active:scale-100"
        >
          {phrase}
        </button>
      ))}
    </div>
  );
}

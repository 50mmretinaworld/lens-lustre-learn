/**
 * "★ Set as Featured photo" / "Remove Featured photo" — the gold line in the ⋯
 * menu of a member's OWN public photo post (Premium Members Part 2).
 *
 * Shown only to a member who holds the Verified honour (a real user_badges row:
 * the brand account's injected tick does not count). PostCard decides "own,
 * public, a photo"; this decides "honoured" and which of the two lines. Loaded
 * only when the menu opens, and draws nothing until both answers are in.
 *
 * Marking one replaces the old one (one per member, SQL 6000 set_featured_post).
 */
import { Star } from "lucide-react";
import { DropdownMenuItem } from "@/components/ui/dropdown-menu";
import { useFeaturedPostId, useMarkFeaturedPost, useVerifiedHonour } from "@/hooks/profile/usePremiumHonour";

export const SET_FEATURED_TEXT = "Set as Featured photo";
export const REMOVE_FEATURED_TEXT = "Remove Featured photo";

interface Props {
  userId: string;
  postId: string;
}

const FeaturedPhotoMenuItem = ({ userId, postId }: Props) => {
  const honour = useVerifiedHonour(userId);
  const featured = useFeaturedPostId(userId, !!honour.data);
  const mark = useMarkFeaturedPost(userId);

  if (!honour.data || featured.isLoading) return null;
  const isFeatured = featured.data === postId;

  return isFeatured ? (
    <DropdownMenuItem onClick={() => mark.mutate(null)} disabled={mark.isPending} className="py-2.5" data-testid="post-featured-remove">
      <Star className="h-4 w-4 mr-2.5" /> {REMOVE_FEATURED_TEXT}
    </DropdownMenuItem>
  ) : (
    <DropdownMenuItem
      onClick={() => mark.mutate(postId)}
      disabled={mark.isPending}
      /* Gold, light and dark — classes the stylesheet already carries (no new CSS, P13). */
      className="py-2.5 font-semibold text-amber-700 dark:text-amber-400 bg-amber-500/10"
      data-testid="post-featured-set"
    >
      <Star className="h-4 w-4 mr-2.5 fill-current" /> {SET_FEATURED_TEXT}
    </DropdownMenuItem>
  );
};

export default FeaturedPhotoMenuItem;

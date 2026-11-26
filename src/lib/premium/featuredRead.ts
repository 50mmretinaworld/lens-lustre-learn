/**
 * PREMIUM MEMBERS · PART 2 — the Featured photo on the WALL (first download).
 * Kept apart from honour.ts on purpose: the wall and the post card are in the
 * first download (P13 byte ceiling), so only these few lines ride in it; the
 * honour read and the write load with the lazy pieces that use them.
 *
 * DEGRADES QUIETLY: SQL 6000 missing (table absent) reads as "no Featured post".
 */
import { supabase } from "@/integrations/supabase/client";

/** The member's Featured post row (premium_featured_posts → posts, ONE request); null when none. */
export async function readFeaturedPostRow(userId: string): Promise<Record<string, unknown> | null> {
  // supabase-js reports a missing table as `error`, it does not throw.
  const { data, error } = await supabase
    .from("premium_featured_posts" as never)
    .select("post:posts(*)")
    .eq("user_id", userId)
    .maybeSingle();
  const post = (data as { post?: Record<string, unknown> | null } | null)?.post;
  return !error && post ? post : null;
}

/**
 * May the ⋯ menu offer "Set as Featured photo" for this post? Only on the
 * viewer's OWN, PUBLIC, PHOTO post (not a video, not text). Whether the viewer
 * holds the Verified honour is decided by FeaturedPhotoMenuItem itself.
 */
export function canOfferFeatured(
  post: { user_id: string; privacy: string; image_urls?: string[] | null },
  viewerId: string | null | undefined,
  isVideo: boolean,
): boolean {
  return viewerId === post.user_id && post.privacy === "public" && !isVideo && (post.image_urls?.length ?? 0) > 0;
}

/**
 * The profile grid order: the Featured post first, everything else in its own order.
 * `extra` is the Featured post as fetched on its own (used when it is not on the loaded pages).
 */
export function featuredFirst<T extends { id: string }>(posts: T[], featuredId: string | null | undefined, extra?: T | null): T[] {
  const f = featuredId ? posts.find((p) => p.id === featuredId) ?? (extra?.id === featuredId ? extra : null) : null;
  return f && posts[0] !== f ? [f, ...posts.filter((p) => p.id !== featuredId)] : posts;
}

/**
 * PREMIUM MEMBERS · PART 2 — one member's honour: the reads the tick card, the
 * ⋯ menu line and "Share my honour" need, and the Featured-photo write. Loaded
 * only with the lazy pieces that use it (the wall's read is featuredRead.ts).
 *
 *   readVerifiedHonour(id)  is this member honoured (user_badges 'verified'), and since when
 *   readFeaturedPostId(id)  the member's Featured photo post id (premium_featured_posts, SQL 6000)
 *   markFeaturedPost(id)    set / replace / clear (NULL) it — rpc set_featured_post (SQL 6000)
 *
 * DEGRADES QUIETLY: a failed read is "not honoured / no Featured photo / date
 * unknown", never a toast. Only marking a photo reports a failure — the member
 * is waiting for an answer.
 */
import { supabase } from "@/integrations/supabase/client";

export interface VerifiedHonour {
  /** user_badges.assigned_at — null when the row carries none. */
  assignedAt: string | null;
}

/** null = not honoured (or the read failed — the tick card then just leaves the date out). */
export async function readVerifiedHonour(userId: string): Promise<VerifiedHonour | null> {
  try {
    const { data, error } = await supabase
      .from("user_badges")
      .select("assigned_at")
      .eq("user_id", userId)
      .eq("badge_type", "verified")
      .maybeSingle();
    if (error || !data) return null;
    const at = (data as { assigned_at?: unknown }).assigned_at;
    return { assignedAt: typeof at === "string" && at ? at : null };
  } catch {
    return null;
  }
}

export async function readFeaturedPostId(userId: string): Promise<string | null> {
  try {
    const { data, error } = await supabase
      .from("premium_featured_posts" as never)
      .select("post_id")
      .eq("user_id", userId)
      .maybeSingle();
    if (error || !data) return null;
    const id = (data as { post_id?: unknown }).post_id;
    return typeof id === "string" && id ? id : null;
  } catch {
    return null;
  }
}

/** Mark (or, with null, unmark) the signed-in member's Featured photo. Throws a member-facing message. */
export async function markFeaturedPost(postId: string | null): Promise<void> {
  const { error } = await supabase.rpc("set_featured_post" as never, { _post_id: postId } as never);
  if (error) throw new Error(error.message || "Could not update your Featured photo.");
}

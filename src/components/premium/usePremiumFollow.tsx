import { Suspense, lazy, useCallback, useMemo, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { useToggleFollow } from "@/hooks/social/useFriendshipMutations";
import { usePremiumFollowing, type PremiumMember } from "@/hooks/feed/usePremiumMembers";
import { savePendingFollow } from "@/lib/social/pendingFollow";
import { isNativeCapacitorApp } from "@/lib/native/authDeepLink";

const GuestFollowPrompt = lazy(() => import("@/components/premium/GuestFollowPrompt"));

/**
 * FOLLOW ON A PREMIUM MEMBER CARD — the one handler the feed row and the page share.
 *
 * Signed in: the EXISTING follow (useToggleFollow → the offline outbox), shown
 * at once on the card, put back if it fails. Following state for the whole
 * list comes from ONE read (usePremiumFollowing), never one per card.
 *
 * Signed out: the follow is remembered (pendingFollow) and done once after
 * sign-in. Inside the app → the app's own sign-in screen; in a browser → the
 * Join sheet / dialog (GuestFollowPrompt, loaded on demand).
 */
export function usePremiumFollow(members: readonly PremiumMember[]) {
  const { user } = useAuth();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const ids = useMemo(() => members.map((m) => m.user_id), [members]);
  const followingQ = usePremiumFollowing(ids);
  const toggle = useToggleFollow();
  const [busyId, setBusyId] = useState<string | null>(null);
  /** undefined = closed · null = the page's Join button · member = that card's Follow. */
  const [guest, setGuest] = useState<PremiumMember | null | undefined>(undefined);
  const me = user?.id ?? null;
  const key = useMemo(() => ["follows", "premium", me, ids.join(",")] as const, [me, ids]);
  const following = followingQ.data;

  const isFollowing = useCallback((id: string) => following?.has(id) ?? false, [following]);

  const follow = useCallback((m: PremiumMember) => {
    if (!me) {
      savePendingFollow({ id: m.user_id, name: m.full_name });
      if (isNativeCapacitorApp()) navigate("/login");
      else setGuest(m);
      return;
    }
    const was = following?.has(m.user_id) ?? false;
    const flip = (on: boolean) =>
      qc.setQueryData<Set<string>>(key, (s) => {
        const n = new Set(s ?? []);
        if (on) n.add(m.user_id); else n.delete(m.user_id);
        return n;
      });
    flip(!was);
    setBusyId(m.user_id);
    toggle.mutate(
      { targetUserId: m.user_id, isCurrentlyFollowing: was, successTitle: `You're now following ${m.full_name}` },
      { onError: () => flip(was), onSettled: () => setBusyId(null) },
    );
  }, [me, following, navigate, qc, key, toggle]);

  /** The page's Join button for a signed-out visitor. */
  const join = useCallback(() => {
    if (isNativeCapacitorApp()) navigate("/signup");
    else setGuest(null);
  }, [navigate]);

  const prompt: ReactNode = guest !== undefined ? (
    <Suspense fallback={null}>
      <GuestFollowPrompt member={guest} onClose={() => setGuest(undefined)} />
    </Suspense>
  ) : null;

  return { isFollowing, follow, join, busyId, prompt, selfId: me, signedIn: !!me };
}

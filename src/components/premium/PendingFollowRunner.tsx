import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useToggleFollow } from "@/hooks/social/useFriendshipMutations";
import { clearPendingFollow, readPendingFollow } from "@/lib/social/pendingFollow";

/**
 * DOES THE FOLLOW A VISITOR ASKED FOR BEFORE SIGNING IN — ONCE (Premium Members, Part 4b).
 *
 * Mounted by App.tsx's PendingFollowGate only when someone is signed in AND a
 * follow is remembered on this device. The remembered follow is cleared BEFORE
 * the follow is sent, so a re-render, a second tab or a crash can never send
 * it twice. The follow itself is the existing one (useToggleFollow → outbox;
 * the server keeps one row per pair, so it is safe even if already followed),
 * with its toast worded "You're now following {name}".
 */
export default function PendingFollowRunner({ userId }: { userId: string }) {
  const toggle = useToggleFollow();
  const qc = useQueryClient();
  const done = useRef(false);

  useEffect(() => {
    if (done.current) return;
    done.current = true;
    const p = readPendingFollow();
    clearPendingFollow();
    if (!p || p.id === userId) return;
    toggle.mutate(
      {
        targetUserId: p.id,
        isCurrentlyFollowing: false,
        successTitle: p.name ? `You're now following ${p.name}` : "Following!",
      },
      { onSuccess: () => void qc.invalidateQueries({ queryKey: ["friend-follow", p.id] }) },
    );
  }, [userId, toggle, qc]);

  return null;
}

import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/core/useAuth";
import { toast } from "@/hooks/core/use-toast";
import { submit } from "@/lib/offline/outbox";
import { queryKeys } from "@/lib/queryKeys";
import { clearPendingFollow, readPendingFollow } from "@/lib/social/pendingFollow";

/**
 * DOES THE FOLLOW A VISITOR ASKED FOR BEFORE SIGNING IN — ONCE (Premium Members, Part 4b).
 *
 * Run by the screens a member lands on after signing in: /feed (Login, the
 * app, e-mail confirm, Google), /dashboard (Sign-up) and /premium-members —
 * all loaded on demand, so nothing of this is in the first download (P13).
 *
 * The remembered follow is cleared BEFORE the follow is sent, so a re-render,
 * a second screen or a crash can never send it twice. The follow goes through
 * the SAME offline outbox every Follow button uses (useToggleFollow → submit;
 * the server keeps one row per pair, so it is safe even if already followed),
 * with its own toast: "You're now following {name}".
 */
export function useRunPendingFollow(): void {
  const { user } = useAuth();
  const userId = user?.id ?? null;
  const qc = useQueryClient();
  const doneFor = useRef<string | null>(null);

  useEffect(() => {
    if (!userId || doneFor.current === userId) return;
    const p = readPendingFollow();
    if (!p) return;
    doneFor.current = userId;
    clearPendingFollow();
    if (p.id === userId) return;
    void submit(userId, { kind: "follow", targetId: p.id }).then(
      () => {
        toast({ title: p.name ? `You're now following ${p.name}` : "Following!" });
        void qc.invalidateQueries({ queryKey: ["friend-follow", p.id] });
        void qc.invalidateQueries({ queryKey: queryKeys.follows(), exact: false });
      },
      () => toast({ title: "Failed to follow", variant: "destructive" }),
    );
  }, [userId, qc]);
}

/** The same, as a component (Feed and Dashboard mount it on demand). */
export default function PendingFollowRunner() {
  useRunPendingFollow();
  return null;
}

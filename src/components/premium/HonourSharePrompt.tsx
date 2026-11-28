/**
 * "SHARE MY HONOUR" — ONCE, IN THE APP (Owner bug list 28 Nov, item 6).
 *
 * The first time a member opens the Android / iPhone app after being honoured (Verified, which every Premium
 * Member holds), the Share my honour sheet opens by itself: the image is drawn on the phone and each size has one
 * Share button (the phone's own share menu). Shown once per honour per phone: the key carries the honour's date,
 * so a member honoured again later sees it again. A member with no Featured photo yet gets nothing (no error).
 * Loaded lazily and only inside the app, so the website's first download does not grow.
 */
import { lazy, Suspense, useCallback, useEffect, useState } from "react";
import { useAuth } from "@/hooks/core/useAuth";
import { useVerifiedHonour } from "@/hooks/profile/usePremiumHonour";
import { useProfileMap } from "@/hooks/profile/useProfileMap";

const ShareHonourSheet = lazy(() => import("@/components/premium/ShareHonourSheet"));

/** After the start-up screens (update prompt at 2.5 s) have had their turn. */
const DELAY_MS = 4000;

export const honourPromptKey = (userId: string, assignedAt: string | null) =>
  `honour-share-prompt:${userId}:${assignedAt ?? "unknown"}`;

export default function HonourSharePrompt() {
  const { user } = useAuth();
  const uid = user?.id;
  const honour = useVerifiedHonour(uid);
  const { profileMap } = useProfileMap(uid ? [uid] : []);
  const [show, setShow] = useState(false);
  const close = useCallback(() => setShow(false), []);

  useEffect(() => {
    if (!uid || !honour.data) return;
    const key = honourPromptKey(uid, honour.data.assignedAt);
    try {
      if (localStorage.getItem(key)) return;
    } catch {
      return; // storage blocked: never risk showing it on every start
    }
    const t = setTimeout(() => {
      try { localStorage.setItem(key, "1"); } catch { /* shown once anyway this session */ }
      setShow(true);
    }, DELAY_MS);
    return () => clearTimeout(t);
  }, [uid, honour.data]);

  if (!show || !uid) return null;
  const p = profileMap[uid];
  return (
    <Suspense fallback={null}>
      <ShareHonourSheet
        userId={uid}
        name={p?.full_name || "Member"}
        handle={p?.custom_url ?? null}
        heading="You've been honoured"
        quiet
        onClose={close}
      />
    </Suspense>
  );
}

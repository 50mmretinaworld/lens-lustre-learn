/**
 * "Share my honour" — ONLY on a Verified member's OWN profile (Premium Members
 * Part 5). The caller passes isOwner; this checks the honour (a real
 * user_badges 'verified' row — the brand account's injected tick does not count)
 * and draws nothing otherwise. The image maker loads only on the first tap.
 */
import { lazy, Suspense, useCallback, useState } from "react";
import VerifiedBadge from "@/components/VerifiedBadge";
import { useVerifiedHonour } from "@/hooks/profile/usePremiumHonour";

const ShareHonourSheet = lazy(() => import("@/components/premium/ShareHonourSheet"));

export const SHARE_HONOUR_TEXT = "Share my honour";

interface Props {
  userId: string;
  name: string;
  handle: string | null;
  isOwner: boolean;
  className?: string;
}

const ShareHonourButton = ({ userId, name, handle, isOwner, className = "" }: Props) => {
  const honour = useVerifiedHonour(userId, isOwner);
  const [open, setOpen] = useState(false);
  // Stable: the sheet draws the image in an effect keyed on it.
  const close = useCallback(() => setOpen(false), []);
  if (!isOwner || !honour.data) return null;

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        data-testid="share-honour"
        // Tick blue tint as inline style: no new CSS in the shared stylesheet (P13 initial budget).
        style={{ borderColor: "rgba(29,155,240,0.4)", background: "rgba(29,155,240,0.1)" }}
        className={`inline-flex h-9 items-center justify-center gap-1.5 rounded-lg border px-4 text-[13px] font-semibold text-foreground ${className}`}
      >
        <VerifiedBadge className="h-4 w-4" aria-hidden />
        {SHARE_HONOUR_TEXT}
      </button>
      {open && (
        <Suspense fallback={null}>
          <ShareHonourSheet userId={userId} name={name} handle={handle} onClose={close} />
        </Suspense>
      )}
    </>
  );
};

export default ShareHonourButton;

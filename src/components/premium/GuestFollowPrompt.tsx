import { Link } from "react-router-dom";
import { Sheet, SheetContent, SheetDescription, SheetTitle } from "@/components/ui/sheet";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { APP_STORE_URL, PLAY_STORE_URL, appOfferForThisDevice, joinViaAppUrl } from "@/lib/native/appLinks";
import { memberPath } from "@/lib/urlHelpers";
import PresenceAvatar from "@/components/PresenceAvatar";
import type { PremiumMember } from "@/hooks/feed/usePremiumMembers";

/**
 * A VISITOR WHO IS NOT A MEMBER TAPS FOLLOW OR JOIN (Owner-approved plan, Part 4b).
 *
 * Phone / tablet browser → a bottom sheet with ONE app button, "Join via App":
 *   Android opens the installed app on that member's profile (App Links,
 *   lib/native/appLinks.ts), else Google Play; iPhone / iPad opens the App Store.
 *   "Continue on website" → sign-up. "Already a member? Sign in".
 * Computer browser → a centred dialog: Join free, Sign in, Google Play · App Store.
 *
 * Nothing is followed here. The caller has already remembered the follow
 * (lib/social/pendingFollow.ts); it is done once after sign-in.
 *
 * Loaded on demand — only when a signed-out visitor taps.
 */

const headingFont = { fontFamily: "var(--font-heading)" };
const bodyFont = { fontFamily: "var(--font-body)" };
const primaryBtn =
  "inline-flex h-12 w-full items-center justify-center rounded-lg bg-primary px-4 text-[15px] font-semibold text-primary-foreground hover:opacity-90";
const secondaryBtn =
  "inline-flex h-12 w-full items-center justify-center rounded-lg border border-border px-4 text-[15px] font-semibold text-foreground hover:bg-muted";

interface Props {
  /** The member whose Follow was tapped; null = the page's Join button. */
  member: PremiumMember | null;
  onClose: () => void;
  /** For tests: the device's user agent and touch points. */
  ua?: string;
  touchPoints?: number;
}

function Header({ member, Title, Description }: {
  member: PremiumMember | null;
  Title: typeof SheetTitle | typeof DialogTitle;
  Description: typeof SheetDescription | typeof DialogDescription;
}) {
  return (
    <div className="flex flex-col gap-2 text-left">
      <div className="flex items-center gap-3 pr-8">
        {member && <PresenceAvatar src={member.avatar_url} name={member.full_name} size={40} showRing={false} showDot={false} />}
        <Title className="text-[17px] font-bold leading-tight" style={headingFont}>
          {member ? `Follow ${member.full_name}` : "Join 50mm Retina World"}
        </Title>
      </div>
      <Description className="text-[15px] text-foreground/80" style={bodyFont}>
        Join 50mm Retina World free to follow Premium Members.
      </Description>
    </div>
  );
}

export default function GuestFollowPrompt({ member, onClose, ua, touchPoints }: Props) {
  const desktop = appOfferForThisDevice(ua, false, touchPoints) === "desktop";
  const onOpenChange = (open: boolean) => { if (!open) onClose(); };

  if (desktop) {
    return (
      <Dialog open onOpenChange={onOpenChange}>
        <DialogContent className="max-w-sm rounded-[14px]" data-testid="guest-follow-dialog">
          <Header member={member} Title={DialogTitle} Description={DialogDescription} />
          <div className="flex flex-col gap-2">
            <Link to="/signup" onClick={onClose} className={primaryBtn} style={headingFont}>Join free</Link>
            <Link to="/login" onClick={onClose} className={secondaryBtn} style={headingFont}>Sign in</Link>
          </div>
          <p className="text-center text-xs text-muted-foreground" style={bodyFont}>
            Prefer the app?{" "}
            <a href={PLAY_STORE_URL} target="_blank" rel="noopener noreferrer" className="inline-block py-1 underline hover:text-foreground">Google Play</a>
            {" · "}
            <a href={APP_STORE_URL} target="_blank" rel="noopener noreferrer" className="inline-block py-1 underline hover:text-foreground">App Store</a>
          </p>
        </DialogContent>
      </Dialog>
    );
  }

  const appUrl = joinViaAppUrl((member && memberPath(member.handle)) || "/premium-members", ua, touchPoints);
  return (
    <Sheet open onOpenChange={onOpenChange}>
      <SheetContent
        side="bottom"
        data-testid="guest-follow-sheet"
        className="flex flex-col gap-4 rounded-t-[20px] px-4 pt-5 pb-[calc(1.5rem+var(--safe-bottom,0px))]"
      >
        <Header member={member} Title={SheetTitle} Description={SheetDescription} />
        <div className="flex flex-col gap-2">
          {appUrl && (
            <a href={appUrl} data-testid="join-via-app" className={primaryBtn} style={headingFont}>Join via App</a>
          )}
          <Link to="/signup" onClick={onClose} className={appUrl ? secondaryBtn : primaryBtn} style={headingFont}>
            Continue on website
          </Link>
        </div>
        <p className="text-center text-sm text-muted-foreground" style={bodyFont}>
          Already a member?{" "}
          <Link to="/login" onClick={onClose} className="inline-flex min-h-11 items-center font-semibold text-primary hover:underline">
            Sign in
          </Link>
        </p>
      </SheetContent>
    </Sheet>
  );
}

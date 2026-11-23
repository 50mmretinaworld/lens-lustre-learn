/**
 * Another member's profile — what a VISITOR can do (Owner 22 Nov 2026, with phone screenshots):
 *  · ONE row of three equal buttons that always fits the phone: Add Friend · Chat · Follow.
 *    After following, the SAME third button becomes ☆ Favourite (★ when on) — one button, two jobs.
 *  · Everything else — Unfollow, Unfriend, Unmute, Block — lives under ⋮ (a dangerous action is never a main button).
 *  · The official 50mm Retina World account can never be blocked or unfollowed, and has no friend button.
 * Buttons are flex-1 basis-0 min-w-0 with truncating labels: the row can never be wider than the screen (it was, and the
 * whole page slid sideways).
 */
import { useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { Ban, Check, Clock, MessageCircle, MoreVertical, Star, UserCheck, UserMinus, UserPlus, UserX, Volume2 } from "lucide-react";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { useAuth } from "@/hooks/core/useAuth";
import { useBlockedUsers } from "@/hooks/core/useBlockedUsers";
import { useFriendFollow } from "@/hooks/social/useFriendFollow";
import { useMessagingAllowed } from "@/hooks/messages/useMessagingAllowed";
import { useCanReachMember } from "@/hooks/messages/useCanReachMember";
import { useAuthorPrefs } from "@/components/profile/FavouriteMuteButtons";
import BlockUserDialog from "@/components/moderation/BlockUserDialog";
import PendingMark from "@/components/offline/PendingMark";
import { useT } from "@/i18n/I18nContext";

const BTN = "inline-flex h-9 min-w-0 flex-1 basis-0 items-center justify-center gap-1.5 rounded-lg px-2 text-[13px] font-semibold transition-colors disabled:opacity-50";
const SOFT = "bg-foreground/[0.08] text-foreground hover:bg-foreground/[0.12]";
const MAIN = "bg-primary text-primary-foreground hover:opacity-90";

export function VisitorActionRow({ targetUserId, displayName }: { targetUserId: string; displayName: string }) {
  const t = useT();
  const navigate = useNavigate();
  const { user } = useAuth();
  const { friendStatus, isFollowing, loading, isSelf, isTargetAdmin, sendFriendRequest, acceptFriendRequest, removeFriend, toggleFollow } = useFriendFollow(targetUserId);
  const iMayMessage = useMessagingAllowed();
  const theyHaveChat = useCanReachMember(targetUserId);
  const canMessage = iMayMessage && theyHaveChat;
  const fav = useAuthorPrefs(user?.id, targetUserId, displayName);
  if (isSelf) return null;
  const showChat = canMessage && (isFollowing || friendStatus === "accepted" || isTargetAdmin);
  const label = (s: string) => <span className="truncate">{s}</span>;

  return (
    <div className="flex w-full min-w-0 items-center gap-1.5" data-testid="visitor-actions">
      {/* 1 · friend (not for the official account) */}
      {!isTargetAdmin && friendStatus === "none" && (
        <button type="button" onClick={sendFriendRequest} disabled={loading} className={`${BTN} ${SOFT}`} data-testid="action-friend">
          <UserPlus className="h-4 w-4 shrink-0" />{label(t("fr.addFriend", "Add Friend"))}
        </button>
      )}
      {!isTargetAdmin && friendStatus === "pending_sent" && (
        <button type="button" onClick={() => { if (window.confirm(t("fr.cancelConfirm", "Cancel your friend request?"))) void removeFriend(); }} disabled={loading} className={`${BTN} ${SOFT} text-muted-foreground`} data-testid="action-friend">
          <Clock className="h-4 w-4 shrink-0" />{label(t("fr.requested", "Requested"))}
        </button>
      )}
      {!isTargetAdmin && friendStatus === "pending_received" && (
        <button type="button" onClick={acceptFriendRequest} disabled={loading} className={`${BTN} ${MAIN}`} data-testid="action-friend">
          <UserCheck className="h-4 w-4 shrink-0" />{label(t("fr.accept", "Accept"))}
        </button>
      )}
      {!isTargetAdmin && friendStatus === "accepted" && (
        <span className={`${BTN} ${SOFT} cursor-default`} data-testid="action-friend">
          <Check className="h-4 w-4 shrink-0" />{label(t("fr.friends", "Friends"))}
        </span>
      )}

      {/* 2 · chat */}
      {showChat && (
        <button type="button" data-testid="message-btn" onClick={() => navigate(`/messages/with/${targetUserId}`)} className={`${BTN} ${SOFT}`}>
          <MessageCircle className="h-4 w-4 shrink-0" />{label(t("nav.chat", "Chat"))}
        </button>
      )}

      {/* 3 · follow → after following, the same button is Favourite */}
      {!isFollowing ? (
        <button type="button" onClick={toggleFollow} disabled={loading} className={`${BTN} ${MAIN}`} data-testid="action-follow">
          {label(t("fr.follow", "Follow"))}
        </button>
      ) : fav.enabled ? (
        <button
          type="button"
          onClick={fav.toggleFavourite}
          disabled={!fav.loaded}
          aria-pressed={fav.prefs.favourite}
          className={`${BTN} ${fav.prefs.favourite ? "bg-primary/15 text-primary hover:bg-primary/20" : SOFT}`}
          data-testid="profile-favourite-button"
        >
          <Star className="h-4 w-4 shrink-0" fill={fav.prefs.favourite ? "currentColor" : "none"} />{label(fav.prefs.favourite ? t("fr.favourited", "Favourite") : t("fr.favourite", "Favourite"))}
        </button>
      ) : (
        <span className={`${BTN} ${SOFT} cursor-default`} data-testid="action-follow">
          <Check className="h-4 w-4 shrink-0" />{label(t("fr.following", "Following"))}
        </span>
      )}
      <PendingMark subject={`follow:${targetUserId}`} />
    </div>
  );
}

/** ⋮ for a visitor: the page's own items (Works, About) + Unfollow, Unfriend, Unmute, Block. In the top bar on a phone. */
export function VisitorMenu({ targetUserId, displayName, children, triggerClassName = "" }: { targetUserId: string; displayName: string; children?: ReactNode; triggerClassName?: string }) {
  const t = useT();
  const { user } = useAuth();
  const { friendStatus, isFollowing, isTargetAdmin, removeFriend, toggleFollow } = useFriendFollow(targetUserId);
  const { isBlocked, unblock } = useBlockedUsers();
  const fav = useAuthorPrefs(user?.id, targetUserId, displayName);
  const [confirmBlock, setConfirmBlock] = useState(false);
  const blocked = isBlocked(targetUserId);
  const item = "flex cursor-pointer items-center gap-2.5 text-sm";
  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button type="button" aria-label={t("profile.menu", "More options")} data-testid="visitor-menu" className={`grid h-11 w-11 place-items-center rounded-lg text-foreground transition-colors hover:bg-foreground/[0.06] ${triggerClassName}`}>
            <MoreVertical className="h-5 w-5" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-56">
          {children}
          {isFollowing && !isTargetAdmin && (
            <DropdownMenuItem className={item} onSelect={() => { if (window.confirm(t("fr.unfollowConfirm", "Unfollow {name}?").replace("{name}", displayName))) void toggleFollow(); }} data-testid="menu-unfollow">
              <UserMinus className="h-4 w-4" />{t("fr.unfollow", "Unfollow")}
            </DropdownMenuItem>
          )}
          {friendStatus === "accepted" && (
            <DropdownMenuItem className={item} onSelect={() => { if (window.confirm(t("fr.unfriendConfirm", "Remove {name} from your friends?").replace("{name}", displayName))) void removeFriend(); }} data-testid="menu-unfriend">
              <UserX className="h-4 w-4" />{t("fr.unfriend", "Unfriend")}
            </DropdownMenuItem>
          )}
          {fav.enabled && fav.prefs.muted && (
            <DropdownMenuItem className={item} onSelect={fav.unmute} data-testid="profile-unmute-button">
              <Volume2 className="h-4 w-4" />{t("fr.unmute", "Unmute")}
            </DropdownMenuItem>
          )}
          {!isTargetAdmin && user && user.id !== targetUserId && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuItem
                className={`${item} ${blocked ? "" : "text-destructive focus:text-destructive"}`}
                onSelect={() => (blocked ? unblock(targetUserId) : setConfirmBlock(true))}
                data-testid="profile-block-button"
              >
                {blocked ? <UserCheck className="h-4 w-4" /> : <Ban className="h-4 w-4" />}{blocked ? t("fr.unblock", "Unblock") : t("fr.block", "Block")}
              </DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
      <BlockUserDialog target={confirmBlock ? { id: targetUserId, name: displayName } : null} onClose={() => setConfirmBlock(false)} />
    </>
  );
}

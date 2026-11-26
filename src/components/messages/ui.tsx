/**
 * Messages · ONE look for every messenger screen (Owner 22 Nov 2026: "compact, premium, small, the app's own pattern,
 * a back arrow"). The list, a one-to-one chat and a group chat all take their header, back arrow, scroll area, notes and
 * composer from here — change a size here and every messenger screen follows (central control, never screen by screen).
 * Pattern = the app's own pages (Notifications: "← Title" bar, thin divider, plain rows), sizes = Instagram DM.
 */
import type { ReactNode } from "react";
import { ArrowLeft } from "lucide-react";
import { useT } from "@/i18n/I18nContext";

export const MSG = {
  /** the app's back arrow (same control as Notifications): 20 px icon, 44 px touch area */
  backBtn: "p-1 -ml-1 tap-44 shrink-0 text-foreground transition-colors hover:text-primary",
  /** a 36 px round icon button in a header */
  iconBtn: "grid h-9 w-9 shrink-0 place-items-center rounded-full text-foreground/80 transition-colors hover:bg-foreground/[0.06] hover:text-foreground",
  /** a scrolling area: no visible scrollbar (phone and app) */
  scroll: "min-h-0 flex-1 overflow-y-auto overscroll-contain scrollbar-hide",
  /** a one-line note in place of the composer (read only, announcement only, sending off) */
  note: "shrink-0 border-t border-border bg-background px-4 py-3 text-center text-xs text-muted-foreground",
  // pb: the iPhone home-indicator strip (--safe-bottom, 0 elsewhere) — a phone chat has no bottom bar under it
  composerWrap: "relative shrink-0 border-t border-border bg-background px-3 pb-[max(0.5rem,var(--safe-bottom))] pt-2",
  composerPill: "flex items-end gap-0.5 rounded-[22px] border border-border bg-foreground/[0.04] px-1 py-1 transition-colors focus-within:border-primary/60",
  composerIcon: "grid h-9 w-9 shrink-0 place-items-center rounded-full text-muted-foreground transition-colors hover:text-foreground disabled:opacity-50",
  composerInput: "max-h-32 min-h-9 flex-1 resize-none bg-transparent px-1.5 py-2 text-[14px] leading-5 placeholder:text-muted-foreground focus:outline-none",
  sendBtn: "mb-0.5 mr-0.5 grid h-8 w-8 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground transition-opacity disabled:opacity-35",
  menuItem: "flex cursor-pointer items-center gap-2 text-sm",
  /** text of a small pill button (accept / decline / suggested reply) */
  pill: "inline-flex h-8 shrink-0 items-center justify-center whitespace-nowrap rounded-full px-3.5 text-[13px] font-semibold transition-colors disabled:opacity-50",
} as const;

export function BackButton({ onClick, className = "" }: { onClick: () => void; className?: string }) {
  const t = useT();
  return (
    <button type="button" onClick={onClick} aria-label={t("common.back", "Back")} data-testid="messages-back" className={`${MSG.backBtn} ${className}`}>
      <ArrowLeft className="h-5 w-5" />
    </button>
  );
}

/** The list's top bar: ← Messages … actions. Without onBack (admin viewer) the title stands alone. */
export function PageBar({ title, onBack, actions }: { title: string; onBack?: () => void; actions?: ReactNode }) {
  return (
    <div className="flex h-14 shrink-0 items-center gap-3 border-b border-border px-4">
      {onBack && <BackButton onClick={onBack} />}
      <h1 className="min-w-0 flex-1 truncate text-[17px] font-bold leading-tight text-foreground">{title}</h1>
      {actions}
    </div>
  );
}

/** A chat's top bar: ← [who] … actions. The back arrow hides on wide screens, where the list is beside the chat. */
export function ChatHeader({ onBack, children, actions }: { onBack: () => void; children: ReactNode; actions?: ReactNode }) {
  return (
    <header className="flex h-14 shrink-0 items-center gap-2 border-b border-border bg-background px-3">
      <BackButton onClick={onBack} className="lg:hidden" />
      <div className="flex min-w-0 flex-1 items-center">{children}</div>
      {actions && <div className="flex shrink-0 items-center">{actions}</div>}
    </header>
  );
}

/** Name (+ badge) over one small line (Active now · @handle / 3 members). */
export function HeaderTitle({ title, sub, badge }: { title: string; sub?: ReactNode; badge?: ReactNode }) {
  return (
    <span className="min-w-0 flex-1">
      <span className="flex min-w-0 items-center gap-1 text-[15px] font-semibold leading-tight text-foreground"><span className="truncate">{title}</span>{badge}</span>
      {sub && <span className="mt-0.5 block truncate text-xs leading-tight text-muted-foreground">{sub}</span>}
    </span>
  );
}

/** "Today" / "Yesterday" / a date between messages: small text, no pill. */
export function DaySeparator({ label }: { label: string }) {
  return <div className="pb-1 pt-4 text-center text-[11px] font-medium text-muted-foreground">{label}</div>;
}

/**
 * A4 · under-review banner. Owner decision (2026-11-15): the member sees ONLY
 * "Your account is under review" and support@50mmretina.com — no reason, no
 * dates, no admin name. Kept literal (not translated) because the Owner fixed
 * the exact words.
 *
 * Renders nothing for an active member or a visitor. One shared banner, mounted
 * once in Layout beside NetworkBanner — never per page.
 */
import { useMyAccountState } from "@/hooks/core/useMyAccountState";

export const ACCOUNT_REVIEW_TEXT = "Your account is under review";
export const SUPPORT_EMAIL = "support@50mmretina.com";

export default function AccountStateBanner() {
  const state = useMyAccountState();
  if (state !== "under_review") return null;
  return (
    <div
      role="status"
      aria-live="polite"
      data-testid="account-state-banner"
      className="w-full bg-amber-100 px-4 py-2 text-center text-sm font-medium text-amber-950 dark:bg-amber-900/60 dark:text-amber-50"
    >
      {ACCOUNT_REVIEW_TEXT}
      <span aria-hidden="true"> · </span>
      <a href={`mailto:${SUPPORT_EMAIL}`} className="underline underline-offset-2">
        {SUPPORT_EMAIL}
      </a>
    </div>
  );
}

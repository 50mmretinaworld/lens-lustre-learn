# iOS App Store rules — the iOS app must never break these

Status: standing rule from the Owner, 2026-11-21. Applies to every change that can reach the
iOS app (all `src/**` — the iOS app bundles the same web code as the website and Android).
Web and Android are never changed by these rules: every gate is `isNativeIOSApp()`.

Apple has already rejected this app once for tracking (5.1.2(i), 4 Nov 2026, version 1.0 build 21).
A rejection costs days. Treat this list as law.

## The rules (what iOS hides or does, and the Apple guideline behind it)

| # | Rule on iOS | Apple guideline | Where it lives |
|---|---|---|---|
| 1 | No Sign in with Apple code, and no Google login. Email sign-in only. | 4.8 | `authDeepLink.ts`, login pages |
| 2 | Members agree to terms (EULA) before registering. Posts, comments and profiles can be reported and blocked; Blocked members screen exists. | 1.2 | `user_blocks`, report/block menus |
| 3 | Delete Account is reachable from Settings and the menus. | 5.1.1(v) | `DeleteAccountSection.tsx`, `UserMenu.tsx` |
| 4 | No wallet, no money: no deposits, withdrawals, gifts, referral earnings, vote rewards, rewarded ads, prize money text, refund policy. | 3.1.1 | `iosReview.ts` (`isWalletNotificationType`, `hasMoneyText`) |
| 5 | Paid courses are hidden from lists and their page redirects, unless the member is already enrolled. Never "Enroll for $". | 3.1.1 | `iosReview.ts` `isPaidCourse` |
| 6 | No tracking: no cookie banner, no third-party analytics, no ad scripts, no questions asked. A cookie box is read as tracking however worded. | 5.1.2(i) | `iosReview.ts` `noThirdPartyTracking()` |
| 7 | No "Ask Anything" box, no Google Play badge, no "Get App" action. | 2.3 / 5.2 | `Layout.tsx`, `Index.tsx` |
| 8 | Lesson videos use youtube-nocookie.com (and the CSP allows it). | 5.1.2(i) | `toYouTubeNoCookie`, `public/_headers` |
| 9 | Test pages render only in development builds. | 2.1 | `App.tsx` |
| 10 | Push: money notification types are never sent to iOS tokens. | 3.1.1 | `supabase/functions/send-push`, kept in step with `iosReview.ts` |
| 11 | Binary: 1024x1024 icon with NO alpha channel; `ITSAppUsesNonExemptEncryption=false`; privacy purpose strings in Info.plist; real logo, never the Capacitor placeholder. | 2.1 / 5.1.1 / 90683 | `.github/workflows/ios-build.yml` (icon step has guards) |

## How to keep the rule (mandatory, every change)

1. **New feature touching money, login, ads, analytics, cookies, external payment links, or
   "get the app" prompts:** gate it with `isNativeIOSApp()` through the helpers in
   `src/lib/native/iosReview.ts`. Add a new helper there rather than an inline check — one place only.
2. **Add the matching assertion** to `src/__tests__/appStoreReviewCompliance.test.ts`.
3. **Before any iOS build:** `appStoreReviewCompliance.test.ts` and `AppleIosNoTracking.test.tsx` must pass.
   A failing compliance test blocks the iOS build — no exceptions.
4. **Database/server text** (prize lines, notification types, course prices) is filtered on the client
   by the helpers above; a new money-like notification type must be added to BOTH
   `iosReview.ts` and `send-push` (they must stay in step).
5. **Never "fix" iOS by removing a gate** to make a feature look equal to Android. Equal features are
   not the goal; passing review is.
6. **Before every iOS upload** compare with the latest Play build, list the feature gaps for the Owner,
   and use a NEW marketing version (a released version string cannot take a new binary).
   Gaps that are deliberate (rows 1–10) are not gaps.
7. `ios-build.yml` changes go by PR to `staging`; builds come from `main` after the carry.

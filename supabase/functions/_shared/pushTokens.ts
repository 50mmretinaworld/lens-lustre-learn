/**
 * PUSH CENTRE PN1 · when is a device token dead? ONE rule, used by send-push
 * and send-broadcast-push (pure — pinned by src/__tests__/pushTokens.test.ts).
 *
 * Until 16 Nov 2026 both functions deleted a token on ANY "INVALID_ARGUMENT".
 * FCM also answers INVALID_ARGUMENT for a bad MESSAGE (a picture or field it
 * will not take), so one bad send could remove every good phone from the list
 * — and the next send reached fewer people with no reason shown.
 *
 * Dead only when FCM says the TOKEN is the problem:
 *   404 / NOT_FOUND / UNREGISTERED   the app was removed or the token rotated
 *   SENDER_ID_MISMATCH               the token belongs to another Firebase project
 *   400 whose message names the registration token itself
 * Anything else (quota, 5xx, a bad message) keeps the token.
 */
interface FcmErrorBody {
  error?: {
    code?: unknown;
    status?: unknown;
    message?: unknown;
    details?: Array<{ errorCode?: unknown }>;
  };
}

function parse(body: string): FcmErrorBody["error"] | null {
  try {
    const p = JSON.parse(body) as FcmErrorBody;
    return p && typeof p === "object" && p.error && typeof p.error === "object" ? p.error : null;
  } catch {
    return null;
  }
}

/** FCM's specific reason (details[].errorCode), e.g. UNREGISTERED — or "". */
export function fcmDetailCode(body: string): string {
  const e = parse(body);
  for (const d of e?.details ?? []) {
    if (typeof d?.errorCode === "string" && /^[A-Z_]{1,40}$/.test(d.errorCode)) return d.errorCode;
  }
  return "";
}

export function isDeadToken(status: number, body: string): boolean {
  const e = parse(body);
  const detail = fcmDetailCode(body);
  const word = typeof e?.status === "string" ? e.status : "";
  const message = typeof e?.message === "string" ? e.message : "";
  if (status === 404 || word === "NOT_FOUND" || detail === "UNREGISTERED") return true;
  if (detail === "SENDER_ID_MISMATCH") return true;
  if (status === 400 && /registration token/i.test(message)) return true;
  return false;
}

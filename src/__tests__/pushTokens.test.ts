import { describe, it, expect } from "vitest";
import { isDeadToken, fcmDetailCode } from "../../supabase/functions/_shared/pushTokens";

const fcm = (code: number, status: string, message: string, detail?: string) =>
  JSON.stringify({
    error: {
      code, status, message,
      details: detail ? [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: detail }] : [],
    },
  });

describe("isDeadToken — remove a phone only when FCM blames the token (PN1 item 5)", () => {
  it("removes an uninstalled / rotated token", () => {
    expect(isDeadToken(404, fcm(404, "NOT_FOUND", "Requested entity was not found.", "UNREGISTERED"))).toBe(true);
  });
  it("removes a token from another Firebase project", () => {
    expect(isDeadToken(403, fcm(403, "PERMISSION_DENIED", "SenderId mismatch", "SENDER_ID_MISMATCH"))).toBe(true);
  });
  it("removes a malformed registration token", () => {
    expect(isDeadToken(400, fcm(400, "INVALID_ARGUMENT", "The registration token is not a valid FCM registration token", "INVALID_ARGUMENT"))).toBe(true);
  });
  it("KEEPS the phone when the MESSAGE is bad (the old rule removed it)", () => {
    expect(isDeadToken(400, fcm(400, "INVALID_ARGUMENT", "Invalid value at 'message.android.notification.image'", "INVALID_ARGUMENT"))).toBe(false);
  });
  it("keeps the phone on quota, server errors and unreadable answers", () => {
    expect(isDeadToken(429, fcm(429, "RESOURCE_EXHAUSTED", "Quota exceeded", "QUOTA_EXCEEDED"))).toBe(false);
    expect(isDeadToken(503, fcm(503, "UNAVAILABLE", "The service is currently unavailable.", "UNAVAILABLE"))).toBe(false);
    expect(isDeadToken(500, "<html>oops</html>")).toBe(false);
  });
  it("reads the specific FCM reason", () => {
    expect(fcmDetailCode(fcm(404, "NOT_FOUND", "x", "UNREGISTERED"))).toBe("UNREGISTERED");
    expect(fcmDetailCode("not json")).toBe("");
  });
});

describe("both senders use the one rule", () => {
  it("send-push and send-broadcast-push call isDeadToken and no longer match INVALID_ARGUMENT blindly", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    for (const f of ["send-push", "send-broadcast-push"]) {
      const src = readFileSync(join(process.cwd(), `supabase/functions/${f}/index.ts`), "utf8");
      expect(src, f).toMatch(/isDeadToken\(/);
      expect(src, f).not.toMatch(/UNREGISTERED\|INVALID_ARGUMENT/);
    }
  });
});

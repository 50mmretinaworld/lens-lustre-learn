import { describe, it, expect } from "vitest";
import { pinFunctionRegion, FUNCTION_REGION } from "@/lib/net/functionRegion";

const BASE = "https://abcdefghijklmnopqrst.supabase.co";

describe("N1 · edge functions run next to the database", () => {
  it("pins to the database region (Seoul)", () => {
    expect(FUNCTION_REGION).toBe("ap-northeast-2");
  });

  it("adds forceFunctionRegion to an edge function URL", () => {
    expect(pinFunctionRegion(`${BASE}/functions/v1/dashboard-init`)).toBe(
      `${BASE}/functions/v1/dashboard-init?forceFunctionRegion=ap-northeast-2`,
    );
  });

  it("keeps an existing query string", () => {
    const out = new URL(pinFunctionRegion(`${BASE}/functions/v1/handle-email-unsubscribe?token=abc`));
    expect(out.searchParams.get("token")).toBe("abc");
    expect(out.searchParams.get("forceFunctionRegion")).toBe("ap-northeast-2");
  });

  it("never touches REST, auth, storage or realtime URLs", () => {
    for (const u of [
      `${BASE}/rest/v1/site_settings?select=key`,
      `${BASE}/rest/v1/rpc/get_broadcast_feed`,
      `${BASE}/auth/v1/token?grant_type=refresh_token`,
      `${BASE}/storage/v1/object/public/a/b.webp`,
    ]) expect(pinFunctionRegion(u)).toBe(u);
  });

  it("does not add the parameter twice", () => {
    const once = pinFunctionRegion(`${BASE}/functions/v1/x`);
    expect(pinFunctionRegion(once)).toBe(once);
  });

  it("passes URL and Request objects through unchanged", () => {
    const u = new URL(`${BASE}/functions/v1/x`);
    expect(pinFunctionRegion(u)).toBe(u);
  });
});

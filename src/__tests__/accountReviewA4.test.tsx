/**
 * A4 · under-review banner + admin account review.
 * The database is the guard (PROBE_20261115_1310 / 1330); this pins the client
 * contract: exact Owner text, fail-quiet banner, one action → the right rpc.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const state = { value: "active" as "active" | "under_review" };
vi.mock("@/hooks/core/useMyAccountState", () => ({ useMyAccountState: () => state.value }));

import AccountStateBanner, { ACCOUNT_REVIEW_TEXT, SUPPORT_EMAIL } from "@/components/AccountStateBanner";
import { actionCall, parseAccountReviews, parseAccountStateLog } from "@/hooks/admin/useAccountReviews";

describe("A4 under-review banner", () => {
  beforeEach(() => { state.value = "active"; });

  it("shows nothing for an active member", () => {
    const { container } = render(<AccountStateBanner />);
    expect(container.firstChild).toBeNull();
  });

  it("shows ONLY the Owner's words and the support e-mail", () => {
    state.value = "under_review";
    render(<AccountStateBanner />);
    const b = screen.getByTestId("account-state-banner");
    expect(ACCOUNT_REVIEW_TEXT).toBe("Your account is under review");
    expect(SUPPORT_EMAIL).toBe("support@50mmretina.com");
    expect(b.textContent).toBe("Your account is under review · Contact support@50mmretina.com");
    expect(screen.getByRole("link").getAttribute("href")).toBe("mailto:support@50mmretina.com");
  });

  it("is mounted once, in Layout", () => {
    const layout = readFileSync(join(__dirname, "../components/Layout.tsx"), "utf8");
    expect(layout.match(/<AccountStateBanner \/>/g)?.length).toBe(1);
  });
});

describe("A4 parseMyAccountState fails quiet", async () => {
  const { parseMyAccountState } = await vi.importActual<typeof import("@/hooks/core/useMyAccountState")>("@/hooks/core/useMyAccountState");
  it("only the exact string turns the banner on", () => {
    expect(parseMyAccountState("under_review")).toBe("under_review");
    for (const v of ["active", null, undefined, "UNDER_REVIEW", 1, {}]) expect(parseMyAccountState(v)).toBe("active");
  });
});

describe("A4 admin actions → rpc", () => {
  const u = "00000000-0000-0000-0000-000000000001";
  it("maps each action to its one admin rpc", () => {
    expect(actionCall({ kind: "under_review", userId: u, reason: "r" })).toEqual(["admin_set_account_state", { _user_id: u, _state: "under_review", _reason: "r" }]);
    expect(actionCall({ kind: "active", userId: u, reason: "r" })).toEqual(["admin_set_account_state", { _user_id: u, _state: "active", _reason: "r" }]);
    expect(actionCall({ kind: "approve", userId: u, reason: "r" })).toEqual(["admin_decide_deletion", { _user_id: u, _decision: "approve", _reason: "r" }]);
    expect(actionCall({ kind: "hold", userId: u, reason: "r" })).toEqual(["admin_decide_deletion", { _user_id: u, _decision: "hold", _reason: "r" }]);
    expect(actionCall({ kind: "delete", userId: u, reason: "r" })).toEqual(["admin_delete_member", { _user_id: u, _reason: "r" }]);
  });

  it("drops malformed rows, keeps good ones", () => {
    const good = { user_id: u, full_name: "A", state: "under_review", reason: "x", set_at: "2026-11-15T00:00:00Z", set_by_name: null, deletion_requested_at: null, auto_approve_at: null };
    expect(parseAccountReviews([good, { ...good, state: "banned" }, { state: "under_review" }, null])).toHaveLength(1);
    expect(parseAccountReviews("nope")).toEqual([]);
    expect(parseAccountStateLog([{ created_at: "t", to_state: "active", from_state: "under_review", reason: null, actor_name: null }, { to_state: "x" }])).toHaveLength(1);
  });
});

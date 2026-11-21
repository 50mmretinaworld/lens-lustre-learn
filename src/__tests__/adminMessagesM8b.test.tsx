/**
 * M8b · Admin → Messages page.
 * The database is the guard (PROBEs 1300 / 1400 / 1800 / 2000: admin only, a reason on every
 * change, a log row before any text is returned). This pins the client: parsers never throw,
 * the page shows the launch state, a change cannot be sent without a reason, and the reason
 * travels to the right rpc.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  sampleMessageAdminState, sampleWordRules, sampleReports, sampleWatchlist, sampleMemberChats, sampleReadConversation,
} from "@/uiharness/adminMessagesSample";

const calls: { fn: string; args?: Record<string, unknown> }[] = [];
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc: (fn: string, args?: Record<string, unknown>) => {
      calls.push({ fn, args });
      const answers: Record<string, unknown> = {
        message_admin_state: sampleMessageAdminState(),
        admin_message_word_rules: sampleWordRules(),
        admin_message_reports: sampleReports(),
        admin_message_watchlist: sampleWatchlist(),
        admin_message_report_done: true,
        admin_message_member_chats: sampleMemberChats(),
        admin_read_conversation: sampleReadConversation(),
        message_admin_set_mode: args?._mode,
      };
      return fn in answers ? Promise.resolve({ data: answers[fn], error: null }) : Promise.resolve({ data: null, error: { message: "unexpected rpc " + fn } });
    },
  },
}));
vi.mock("@/hooks/core/useAuth", () => ({ useAuth: () => ({ user: { id: "11111111-1111-4111-8111-111111111111" } }) }));

import AdminMessages from "@/pages/admin/AdminMessages";
import {
  parseMessageAdminState, parseWordRules, parseReports, parseWatchlist, parseMemberChats, parseViewedChat,
} from "@/hooks/admin/useAdminMessages";

const renderPage = () => {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={qc}><AdminMessages /></QueryClientProvider>);
};

beforeEach(() => { calls.length = 0; });

describe("M8b parsers", () => {
  it("never throw on junk and drop malformed rows", () => {
    expect(parseMessageAdminState(null).mode).toBe("allowed_selected");
    expect(parseMessageAdminState({ mode: "weird", members: [{ nope: 1 }] }).members).toEqual([]);
    expect(parseWordRules("x")).toEqual([]);
    expect(parseWordRules([{ id: 1, category: "abuse", pattern: "x", action: "weird" }])).toEqual([]);
    expect(parseWordRules([{ id: 2, category: "abuse", pattern: "x", action: "hold" }])).toEqual([]);   // hold no longer exists
    expect(parseReports([{ id: "7", conversation_id: "c", reporter_id: "s", created_at: "2026-11-21T00:00:00Z", reason: "weird" }])[0].reason).toBe("other");
    expect(parseWatchlist([{ nope: 1 }])).toEqual([]);
    expect(parseMemberChats([{ conversation_id: "c", messages: "3", others: [{ nope: 1 }] }])[0].messages).toBe(3);
    expect(parseViewedChat({ nope: 1 })).toBeNull();
  });

  it("the chat list carries no message text", () => {
    const rows = parseMemberChats(sampleMemberChats());
    expect(rows.length).toBeGreaterThan(0);
    for (const r of rows) expect(Object.keys(r)).not.toContain("body");
  });
});

describe("M8b page", () => {
  it("shows the launch state: only people on my list, the Owner on it, three open reports", async () => {
    renderPage();
    expect((await screen.findByTestId("messages-status")).textContent).toContain("Only people on my list");
    expect(screen.getByTestId("messages-status").textContent).toContain("3 open reports");
    expect(screen.getAllByTestId("messages-list-row")).toHaveLength(1);
    expect(screen.getByTestId("messages-rules").textContent).toContain("Somnath Roy");
  });

  it("a change asks for a reason first and sends it with the new mode", async () => {
    renderPage();
    fireEvent.click(await screen.findByRole("radio", { name: /Everyone except my list/ }));
    const confirm = await screen.findByRole("button", { name: "Change" });
    expect((confirm as HTMLButtonElement).disabled).toBe(true);                       // no reason, no change
    expect(calls.some((c) => c.fn === "message_admin_set_mode")).toBe(false);
    fireEvent.change(screen.getByTestId("messages-reason"), { target: { value: "Open it up" } });
    fireEvent.click(screen.getByRole("button", { name: "Change" }));
    await waitFor(() => expect(calls.find((c) => c.fn === "message_admin_set_mode")?.args).toEqual({ _mode: "blocked_selected", _reason: "Open it up" }));
  });

  it("Reports tab lists what members reported + the watch list; closing one needs no reason box", async () => {
    renderPage();
    fireEvent.mouseDown(await screen.findByRole("tab", { name: /Reports/ }), { button: 0 });
    expect((await screen.findAllByTestId("messages-report-row")).length).toBe(3);
    expect((await screen.findAllByTestId("messages-watch-row")).length).toBe(2);
    expect(screen.queryByTestId("messages-reason")).toBeNull();
    fireEvent.click(screen.getAllByRole("button", { name: /Mark done/ })[0]);
    await waitFor(() => expect(calls.find((c) => c.fn === "admin_message_report_done")?.args).toMatchObject({ _id: 12 }));
  });

  it("the word list has no Hold: only Block and Help can be added", async () => {
    renderPage();
    fireEvent.mouseDown(await screen.findByRole("tab", { name: /Word guard/ }), { button: 0 });
    const what = (await screen.findByLabelText("What happens")) as HTMLSelectElement;
    expect([...what.options].map((o) => o.value)).toEqual(["block", "help"]);
  });

  it("is registered once in AdminPanel, for super admins only", () => {
    const panel = readFileSync(join(__dirname, "../pages/AdminPanel.tsx"), "utf8");
    expect(panel.match(/<AdminMessages \/>/g)?.length).toBe(1);
    expect(panel).toContain('["messages", "Messages", MessageSquare]');
    const access = readFileSync(join(__dirname, "../lib/adminRoleAccess.ts"), "utf8");
    const roleLists = access.slice(access.indexOf("ROLE_TAB_ACCESS"));
    expect(roleLists).not.toContain('"messages"');                                     // not given to moderators or editors
  });
});

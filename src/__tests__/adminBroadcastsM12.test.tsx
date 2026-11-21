/**
 * M12 · Admin → Messages → Broadcast.
 * The database does the sending and the checking (PROBE_20261118_2300). This pins the client: parsers never throw,
 * the list shows progress, one broadcast's report shows delivered / failed / read per batch and per member with the
 * double tick, "send" saves then asks the server to send (never sends from the browser), and pause goes to the server.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  sampleMessageBroadcasts, sampleBroadcastReport, sampleBroadcastRecipients, sampleBroadcastAudience,
} from "@/uiharness/adminBroadcastsSample";

const calls: { fn: string; args?: Record<string, unknown> }[] = [];
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc: (fn: string, args?: Record<string, unknown>) => {
      calls.push({ fn, args });
      const a = args ?? {};
      const answers: Record<string, unknown> = {
        admin_message_broadcasts: sampleMessageBroadcasts(a),
        admin_message_broadcast_report: sampleBroadcastReport(a),
        admin_message_broadcast_recipients: sampleBroadcastRecipients(a),
        admin_message_broadcast_audience: sampleBroadcastAudience(a),
        admin_message_broadcast_save: 9,
        admin_message_broadcast_send: { broadcast_id: 9, recipients: 5000, batches: 10, engine_on: true },
        admin_message_broadcast_control: "paused",
      };
      return fn in answers ? Promise.resolve({ data: answers[fn], error: null }) : Promise.resolve({ data: null, error: { message: "unexpected rpc " + fn } });
    },
    from: () => ({ select: () => Promise.resolve({ data: [], error: null }) }),
  },
}));
vi.mock("@/hooks/core/useAuth", () => ({ useAuth: () => ({ user: { id: "11111111-1111-4111-8111-111111111111" } }) }));
// the role / badge definition hooks need a full database client; the Broadcast screens only need their labels
vi.mock("@/components/admin/users/memberUi", () => ({
  useMemberLabels: () => ({ allRoles: ["user", "judge", "registered_photographer"], role: (r: string) => ({ label: r, icon: "" }) }),
  MemberAvatar: () => null,
}));

import BroadcastPanel from "@/components/admin/messages/BroadcastPanel";
import { parseBroadcasts, parseBroadcastReport, parseBroadcastRecipients } from "@/hooks/admin/useAdminBroadcasts";

const renderPanel = () => {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={qc}><BroadcastPanel /></QueryClientProvider>);
};
beforeEach(() => { calls.length = 0; });

describe("M12 parsers", () => {
  it("never throw on junk and drop malformed rows", () => {
    expect(parseBroadcasts(null)).toEqual({ total: 0, counts: {}, rows: [] });
    expect(parseBroadcasts({ rows: [{ nope: 1 }, { id: "3", title: "T", created_at: "2026-11-21T00:00:00Z", status: "weird", delivered: "4" }] }).rows[0]).toMatchObject({ id: 3, status: "draft", delivered: 4 });
    expect(parseBroadcastReport({ nope: 1 })).toBeNull();
    expect(parseBroadcastRecipients("x")).toEqual({ total: 0, counts: { all: 0, delivered: 0, read: 0, unread: 0, failed: 0, waiting: 0 }, rows: [] });
  });
  it("the sample report adds up", () => {
    const r = parseBroadcastReport(sampleBroadcastReport({ _id: 7 }));
    expect(r?.totals.audience).toBe(5000);
    expect(r?.batches).toHaveLength(10);
    expect(r!.batches.reduce((n, b) => n + b.delivered + b.failed, 0)).toBe(r!.totals.delivered + r!.totals.failed);
  });
});

describe("M12 page", () => {
  it("lists broadcasts with progress, delivered and read; a row opens its report with every number", async () => {
    renderPanel();
    expect((await screen.findAllByTestId("table-row")).length).toBe(5);
    expect(screen.getByTestId("tab-sending").textContent).toContain("1");
    fireEvent.click(screen.getByText("Welcome to private messages"));
    expect((await screen.findByTestId("bc-total-audience")).textContent).toContain("5,000");
    expect(screen.getByTestId("bc-total-delivered").textContent).toContain("1,488");
    expect(screen.getByTestId("bc-total-read").textContent).toContain("640");
    expect(screen.getByTestId("bc-total-failed").textContent).toContain("12");
    const batches = within(screen.getByTestId("bc-batches")).getAllByTestId("table-row");
    expect(batches).toHaveLength(10);
    // every member with a tick; the Failed tab asks the server for failed members only
    expect((await within(screen.getByTestId("bc-people")).findAllByTestId("bc-person-state")).length).toBeGreaterThan(5);
    fireEvent.click(within(screen.getByTestId("bc-people")).getByTestId("tab-failed"));
    await waitFor(() => expect(calls.some((c) => c.fn === "admin_message_broadcast_recipients" && c.args?._filter === "failed")).toBe(true));
  });

  it("pause is a server call, confirmed first", async () => {
    renderPanel();
    fireEvent.click(await screen.findByText("Welcome to private messages"));
    fireEvent.click(await screen.findByRole("button", { name: /Pause/ }));
    expect(calls.some((c) => c.fn === "admin_message_broadcast_control")).toBe(false);
    fireEvent.click(await screen.findByRole("button", { name: "Pause" }));
    await waitFor(() => expect(calls.find((c) => c.fn === "admin_message_broadcast_control")?.args).toEqual({ _id: 7, _action: "pause" }));
  });

  it("send = save the draft, then ask the server to send; the audience is counted first and the batches are told", async () => {
    renderPanel();
    fireEvent.click(await screen.findByTestId("bc-new"));
    fireEvent.change(await screen.findByTestId("bc-title"), { target: { value: "Hello all" } });
    fireEvent.change(screen.getByTestId("bc-body"), { target: { value: "Hi 👋 see https://50mmretina.com" } });
    await waitFor(() => expect(screen.getByTestId("bc-audience-count").textContent).toContain("4,992"));
    fireEvent.click(screen.getByTestId("bc-review"));
    expect((await screen.findByRole("alertdialog")).textContent).toContain("10 batches");
    expect(calls.some((c) => c.fn === "admin_message_broadcast_send")).toBe(false);          // nothing sent before the confirm
    fireEvent.click(screen.getByTestId("bc-confirm"));
    await waitFor(() => expect(calls.find((c) => c.fn === "admin_message_broadcast_send")?.args).toEqual({ _id: 9, _at: null }));
    const saved = calls.find((c) => c.fn === "admin_message_broadcast_save")?.args as { _fields: Record<string, unknown> };
    expect(saved._fields).toMatchObject({ title: "Hello all", body: "Hi 👋 see https://50mmretina.com", audience: { kind: "all" }, push: true, photos: [] });
  });

  it("the Send button stays off until there is a title, a message and someone to receive it", async () => {
    renderPanel();
    fireEvent.click(await screen.findByTestId("bc-new"));
    expect((await screen.findByTestId("bc-review") as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByTestId("bc-title"), { target: { value: "T" } });
    expect((screen.getByTestId("bc-review") as HTMLButtonElement).disabled).toBe(true);        // no message yet
    fireEvent.change(screen.getByTestId("bc-body"), { target: { value: "x" } });
    await waitFor(() => expect((screen.getByTestId("bc-review") as HTMLButtonElement).disabled).toBe(false));
  });
});

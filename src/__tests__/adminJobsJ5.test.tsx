/**
 * J5a · admin Job Engine page (read only).
 * The database is the guard (PROBE_20261118_0900: admin only, no payload);
 * this pins the client: parsers never throw, plain-word names, the page shows
 * switches, a failure and the job list, and calls only the two read rpcs.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { sampleJobsOverview, sampleJobsList } from "@/uiharness/adminJobsSample";

const calls: string[] = [];
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc: (fn: string, args?: Record<string, unknown>) => {
      calls.push(fn);
      if (fn === "admin_jobs_overview") return Promise.resolve({ data: sampleJobsOverview(), error: null });
      if (fn === "admin_jobs_list") return Promise.resolve({ data: sampleJobsList(args ?? {}), error: null });
      return Promise.resolve({ data: null, error: { message: "unexpected rpc " + fn } });
    },
  },
}));

import AdminJobs, { fmtSeconds } from "@/pages/admin/AdminJobs";
import { parseJobsOverview, parseJobsList, jobKindLabel } from "@/hooks/admin/useAdminJobs";

describe("J5a parsers", () => {
  it("never throw on junk and drop malformed rows", () => {
    expect(parseJobsOverview(null)).toEqual({ checked_at: null, switches: {}, kinds: [], alarms: [] });
    expect(parseJobsOverview({ kinds: [{ nope: 1 }, { kind: "push.send", done_24h: "5" }] }).kinds).toHaveLength(1);
    expect(parseJobsOverview({ kinds: [{ kind: "push.send", done_24h: "5" }] }).kinds[0].done_24h).toBe(5);
    expect(parseJobsList("x")).toEqual([]);
    expect(parseJobsList([{ id: 1, kind: "push.send", status: "weird", created_at: "2026-11-18T00:00:00Z" }])).toEqual([]);
  });

  it("the list shape has no payload", () => {
    const rows = parseJobsList(sampleJobsList({}));
    expect(rows.length).toBeGreaterThan(0);
    for (const r of rows) expect(Object.keys(r)).not.toContain("payload");
  });

  it("plain-word names, unknown kinds as written", () => {
    expect(jobKindLabel("cron.autoscale-ad-traffic")).toBe("Ad traffic");
    expect(jobKindLabel("push.send")).toBe("Push notifications");
    expect(jobKindLabel("something.new")).toBe("something.new");
    expect(fmtSeconds(60)).toBe("60 s");
    expect(fmtSeconds(270.2)).toBe("5 min");
  });
});

describe("J5a page", () => {
  it("shows switches, the failure alarm, every kind and the job list — via the two read rpcs only", async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(<QueryClientProvider client={qc}><AdminJobs /></QueryClientProvider>);
    expect((await screen.findAllByText("Scheduled boosts")).length).toBeGreaterThan(0);
    expect(screen.getAllByTestId("job-switch")).toHaveLength(3);
    expect(screen.getByTestId("job-alarms").textContent).toContain("1 job failed");
    expect(screen.getAllByTestId("job-kind-card")).toHaveLength(8);
    expect((await screen.findAllByTestId("job-row")).length).toBeGreaterThan(0);
    expect(new Set(calls)).toEqual(new Set(["admin_jobs_overview", "admin_jobs_list"]));
  });

  it("is registered once in AdminPanel", () => {
    const panel = readFileSync(join(__dirname, "../pages/AdminPanel.tsx"), "utf8");
    expect(panel.match(/<AdminJobs \/>/g)?.length).toBe(1);
    expect(panel).toContain('["jobs", "Job Engine", Server]');
  });
});

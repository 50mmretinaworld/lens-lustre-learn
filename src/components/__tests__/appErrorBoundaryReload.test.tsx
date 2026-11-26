/**
 * While the page reloads for a missing chunk, the cancelled import throws
 * "reading 'default'": that must not be recorded as fatal or shown to the member.
 * Any other crash is still reported and still gets the Reload screen.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";

let pending = false;
// vi.mock is hoisted above plain consts, so the spies must be hoisted too.
const { fatal, report } = vi.hoisted(() => ({ fatal: vi.fn(), report: vi.fn() }));
vi.mock("@/lib/staleChunkReload", () => ({ isStaleReloadPending: () => pending }));
vi.mock("@/lib/logger", () => ({ logger: { fatal } }));
vi.mock("@/lib/reportClientError", () => ({ reportClientError: report }));

import AppErrorBoundary from "@/components/AppErrorBoundary";

const Boom = (): never => {
  throw new TypeError("Cannot read properties of undefined (reading 'default')");
};

describe("last-resort screen during a reload", () => {
  beforeEach(() => {
    fatal.mockClear();
    report.mockClear();
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  it("stays quiet while the reload is under way", () => {
    pending = true;
    const { container } = render(<AppErrorBoundary><Boom /></AppErrorBoundary>);
    expect(container.textContent).toBe("");
    expect(fatal).not.toHaveBeenCalled();
    expect(report).not.toHaveBeenCalled();
  });

  it("still reports and shows Reload for any other crash", () => {
    pending = false;
    render(<AppErrorBoundary><Boom /></AppErrorBoundary>);
    expect(screen.getByRole("button", { name: "Reload" })).toBeTruthy();
    expect(fatal).toHaveBeenCalledTimes(1);
    expect(report).toHaveBeenCalledTimes(1);
  });
});

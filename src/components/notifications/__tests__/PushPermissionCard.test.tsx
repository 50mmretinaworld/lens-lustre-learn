/**
 * PN4 item 9 — "Turn on notifications" card: shown only when the phone says this
 * app's notifications are off; "Turn on" opens the phone's settings; coming back
 * with them switched on runs push setup again and the card goes.
 */
import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor, act, cleanup } from "@testing-library/react";

const retry = vi.fn(async () => {});
vi.mock("@/lib/native/push", () => ({ retryPushSetup: () => retry() }));

import PushPermissionCard from "@/components/notifications/PushPermissionCard";

function phone(enabled: boolean) {
  const state = { enabled };
  const openSettings = vi.fn(async () => {});
  (window as unknown as { Capacitor: unknown }).Capacitor = {
    Plugins: { PushCentre: { status: async () => ({ enabled: state.enabled, rich: true }), openSettings } },
  };
  return { state, openSettings };
}

afterEach(() => {
  cleanup();
  retry.mockClear();
  delete (window as unknown as { Capacitor?: unknown }).Capacitor;
});

describe("PushPermissionCard", () => {
  it("renders nothing on the web and in builds without the plugin", async () => {
    render(<PushPermissionCard />);
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    expect(screen.queryByTestId("push-permission-card")).toBeNull();
  });

  it("renders nothing when the phone has notifications on", async () => {
    phone(true);
    render(<PushPermissionCard />);
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    expect(screen.queryByTestId("push-permission-card")).toBeNull();
    expect(retry).not.toHaveBeenCalled();
  });

  it("off → card; Turn on opens settings; back with them on → setup again, card gone", async () => {
    const p = phone(false);
    render(<PushPermissionCard />);
    await screen.findByTestId("push-permission-card");
    expect(screen.getByText("Notifications are off")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Turn on" }));
    expect(p.openSettings).toHaveBeenCalledTimes(1);

    p.state.enabled = true; // the member switched them on in Android settings
    await act(async () => { document.dispatchEvent(new Event("visibilitychange")); });
    await waitFor(() => expect(screen.queryByTestId("push-permission-card")).toBeNull());
    await waitFor(() => expect(retry).toHaveBeenCalledTimes(1));
  });

  it("back still off → the card stays, nothing re-registers", async () => {
    phone(false);
    render(<PushPermissionCard />);
    await screen.findByTestId("push-permission-card");
    await act(async () => { document.dispatchEvent(new Event("visibilitychange")); });
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    expect(screen.getByTestId("push-permission-card")).toBeInTheDocument();
    expect(retry).not.toHaveBeenCalled();
  });
});

import { describe, it, expect } from "vitest";
import {
  buildBroadcastMessage, endsLine, legacyTapTarget, safeLink, LEGACY_TAP_PAGES, type BroadcastContent,
} from "../../supabase/functions/_shared/broadcastMessage";
import { getNotifLink } from "@/lib/notificationLinks";
import { isCommentNotificationType } from "@/lib/notificationComment";

const HOSTS = ["cdn.example.test"];
const NOW = Date.parse("2026-11-16T12:00:00Z");
const base: BroadcastContent = {
  id: 42,
  title: "Competition closes soon",
  body: "Last chance to enter",
  image_url: "https://cdn.example.test/a.webp",
  images: ["https://cdn.example.test/1.webp", "https://evil.example/2.webp", "https://cdn.example.test/3.webp"],
  link: "/competitions",
  countdown_until: "2026-11-18T12:30:00Z",
  actions: [{ label: "Enter now", link: "/competitions/42" }, { label: "Bad", link: "https://evil.example" }],
};

describe("plain message — every app build in members' hands today", () => {
  const m = buildBroadcastMessage(base, { token: "t1", caps: [] }, { imageHosts: HOSTS, deliveryId: 7, now: NOW }) as {
    notification: { title: string; body: string; image?: string }; data: Record<string, string>;
  };
  it("is a normal notification with the picture, link and receipt id", () => {
    expect(m.notification.title).toBe("Competition closes soon");
    expect(m.notification.image).toBe("https://cdn.example.test/a.webp");
    expect(m.data).toMatchObject({ broadcast_id: "42", link: "/competitions", delivery_id: "7" });
  });
  it("OWNER BUG 16 Nov: also names the page the way apps ≤ 1.2.49 understand, so a tap opens it", () => {
    // those builds route a tap with getNotifLink(type, reference_id) and ignore `link`
    expect(m.data.type).toBe("new_competition");
    expect(getNotifLink({ type: m.data.type, reference_id: m.data.reference_id ?? null })).toBe("/competitions");
  });
  it("turns the countdown into a fixed 'Ends …' line", () => {
    expect(m.notification.body).toBe(`Last chance to enter\n${endsLine(base.countdown_until as string)}`);
    expect(endsLine("2026-11-18T12:30:00Z")).toBe("Ends 18 Nov, 6:00 pm IST");
  });
});

describe("rich message — builds with caps ['rich']", () => {
  const m = buildBroadcastMessage(base, { token: "t2", caps: ["rich"] }, { imageHosts: HOSTS, deliveryId: 8, now: NOW }) as {
    notification?: unknown; data: Record<string, string>; android: { priority: string; ttl?: string };
  };
  it("is data-only, so the app's own code draws it", () => {
    expect(m.notification).toBeUndefined();
    expect(m.data.type).toBe("broadcast_rich");
    expect(m.android.priority).toBe("high");
  });
  it("carries the countdown end, and FCM drops it after the end", () => {
    expect(m.data.countdown_until).toBe(String(Date.parse("2026-11-18T12:30:00Z")));
    expect(m.android.ttl).toBe(`${(Date.parse("2026-11-18T12:30:00Z") - NOW) / 1000}s`);
  });
  it("keeps only this lane's pictures and in-site buttons", () => {
    expect(JSON.parse(m.data.images)).toEqual(["https://cdn.example.test/1.webp", "https://cdn.example.test/3.webp"]);
    expect(JSON.parse(m.data.actions)).toEqual([{ label: "Enter now", link: "/competitions/42" }]);
    expect(m.data.delivery_id).toBe("8");
  });
  it("drops a countdown that has already ended", () => {
    const past = buildBroadcastMessage({ ...base, countdown_until: "2026-11-01T00:00:00Z" }, { token: "t", caps: ["rich"] },
      { imageHosts: HOSTS, now: NOW }) as { data: Record<string, string>; android: { ttl?: string } };
    expect(past.data.countdown_until).toBeUndefined();
    expect(past.android.ttl).toBeUndefined();
  });
});

describe("legacyTapTarget — every listed page opens through the app's OWN table (no drift)", () => {
  const opens = (link: string) => {
    const t = legacyTapTarget(link);
    return getNotifLink({ type: t.type, reference_id: t.reference_id ?? null });
  };
  it.each([
    ["/", "/"],
    ["/feed", "/feed"],
    ["/competitions", "/competitions"],
    ["/competitions/monsoon-moods", "/competitions/monsoon-moods"],
    ["/journal", "/journal"],
    ["/journal/my-story", "/journal/my-story"],
    ["/courses", "/courses"],
    ["/courses/light-101", "/courses/light-101"],
    ["/post/0b9f6c1e-2c53-4d0c-9d5e-0e8a54a3f001", "/post/0b9f6c1e-2c53-4d0c-9d5e-0e8a54a3f001"],
    ["/friends", "/friends"],
    ["/certificates", "/certificates"],
    ["/discover", "/discover"],
    ["/help-support", "/help-support"],
    ["/wallet", "/wallet"],
    ["/dashboard", "/dashboard"],
  ])("%s opens %s on an old build", (link, page) => {
    expect(opens(link)).toBe(page);
  });
  it("a page old builds do not know opens the dashboard there (and its own address on new builds)", () => {
    expect(legacyTapTarget("/notifications")).toEqual({ type: "broadcast" });
    expect(legacyTapTarget("/competitions/x/submit")).toEqual({ type: "broadcast" });
    expect(legacyTapTarget(null)).toEqual({ type: "broadcast" });
    expect(legacyTapTarget("https://evil.example")).toEqual({ type: "broadcast" });
  });
  it("never uses a comment type (those scroll the post to a comment)", () => {
    for (const p of LEGACY_TAP_PAGES) expect(isCommentNotificationType(legacyTapTarget(p).type)).toBe(false);
    expect(isCommentNotificationType(legacyTapTarget("/post/abc").type)).toBe(false);
  });
  it("every page in the list the admin page shows really opens on an old build", () => {
    for (const p of LEGACY_TAP_PAGES) {
      const link = p === "/post" ? "/post/abc" : p;
      expect(opens(link), p).toBe(link);
    }
  });
});

describe("safety", () => {
  it("a test send says so and carries no receipt", () => {
    const m = buildBroadcastMessage(base, { token: "t", caps: [] }, { imageHosts: HOSTS, test: true, now: NOW }) as {
      notification: { title: string }; data: Record<string, string>;
    };
    expect(m.notification.title).toBe("Test · Competition closes soon");
    expect(m.data.delivery_id).toBeUndefined();
  });
  it("links stay inside the site", () => {
    expect(safeLink("/feed")).toBe("/feed");
    expect(safeLink("//evil.example")).toBeNull();
    expect(safeLink("https://evil.example")).toBeNull();
    expect(safeLink("javascript:alert(1)")).toBeNull();
  });
  it("a picture from another host is never sent", () => {
    const m = buildBroadcastMessage({ ...base, image_url: "https://evil.example/x.webp" }, { token: "t", caps: [] },
      { imageHosts: HOSTS, now: NOW }) as { notification: { image?: string } };
    expect(m.notification.image).toBeUndefined();
  });
});

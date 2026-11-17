/**
 * UI harness — Admin → Push Notification sample (scene screen-admin-push).
 * Synthetic numbers shaped like production on 16 Nov 2026 (154 members,
 * 54 phones of 53 members). Only answers when __harnessAdminPush is set.
 */
const FIX = "/src/uiharness/fixtures";
const H = 3600_000;
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();

export function adminPushSampleOn(): boolean {
  return (globalThis as { __harnessAdminPush?: boolean }).__harnessAdminPush === true;
}

const COUNT = {
  all:      { matched: 154, held: 1, eligible: 153, reachable_members: 53, devices: 54, rich_devices: 0, said_no: 0, app_recent_no_phone: 14, app_old_no_phone: 13, website_only: 73 },
  active7:  { matched: 35,  held: 0, eligible: 35,  reachable_members: 24, devices: 25, rich_devices: 0, said_no: 0, app_recent_no_phone: 4,  app_old_no_phone: 0,  website_only: 7 },
  active30: { matched: 64,  held: 0, eligible: 64,  reachable_members: 41, devices: 42, rich_devices: 0, said_no: 0, app_recent_no_phone: 8,  app_old_no_phone: 0,  website_only: 15 },
  role:     { matched: 9,   held: 0, eligible: 9,   reachable_members: 7,  devices: 7,  rich_devices: 0, said_no: 0, app_recent_no_phone: 1,  app_old_no_phone: 0,  website_only: 1 },
  badge:    { matched: 12,  held: 0, eligible: 12,  reachable_members: 8,  devices: 9,  rich_devices: 0, said_no: 0, app_recent_no_phone: 2,  app_old_no_phone: 1,  website_only: 1 },
};

export function sampleAudience(body: Record<string, unknown>): unknown[] {
  const a = (body._audience ?? { kind: "all" }) as { kind?: string; days?: number; ids?: string[] };
  let c;
  if (a.kind === "active") c = a.days === 7 ? COUNT.active7 : COUNT.active30;
  else if (a.kind === "role") c = COUNT.role;
  else if (a.kind === "badge") c = COUNT.badge;
  else if (a.kind === "members") {
    const n = a.ids?.length ?? 0;
    const r = Math.round(n * 0.7);
    c = { matched: n, held: 0, eligible: n, reachable_members: r, devices: r, rich_devices: 0, said_no: 0, app_recent_no_phone: n - r, app_old_no_phone: 0, website_only: 0 };
  } else c = COUNT.all;
  return [{ ...c, scheduling_on: true }];
}

const base = {
  kind: "message", stuck: false, name: null, images: [], link: "/competitions", countdown_until: null, actions: [],
  audience: { kind: "all" }, job_id: null, created_by_name: "Neil Basu", sent_by_name: "Neil Basu",
  audience_members: null, reached_members: null, devices: null, delivered: 0, failed: 0, removed: 0, opened: 0,
  fail_reasons: {}, scheduled_at: null, started_at: null, finished_at: null,
};

const ROWS = [
  { ...base, id: 31, status: "sent", title: "Monsoon Moods — winners announced", body: "See the 12 photographs the judges chose.",
    image_url: `${FIX}/land-w1500h1000.svg`, link: "/competitions", started_at: iso(-26 * H), finished_at: iso(-26 * H + 40_000),
    created_at: iso(-27 * H), updated_at: iso(-26 * H), audience_members: 153, reached_members: 53, devices: 54,
    delivered: 52, failed: 2, removed: 2, opened: 19, fail_reasons: { "404 UNREGISTERED": 2 } },
  { ...base, id: 30, status: "sent", title: "Street Light challenge closes tonight", body: "Last day to enter — 6 hours left.",
    image_url: `${FIX}/port-w1000h1250.svg`, audience: { kind: "active", days: 30 }, countdown_until: iso(-60 * H),
    started_at: iso(-66 * H), finished_at: iso(-66 * H + 30_000), created_at: iso(-70 * H), updated_at: iso(-66 * H),
    audience_members: 64, reached_members: 41, devices: 42, delivered: 42, failed: 0, removed: 0, opened: 23 },
  { ...base, id: 29, status: "sent", title: "Judges: 18 entries wait for your score", body: "Scoring closes Friday.",
    image_url: null, link: "/dashboard", audience: { kind: "role", role: "judge" }, started_at: iso(-90 * H),
    finished_at: iso(-90 * H + 9_000), created_at: iso(-91 * H), updated_at: iso(-90 * H),
    audience_members: 9, reached_members: 7, devices: 7, delivered: 5, failed: 2, removed: 0, opened: 4,
    fail_reasons: { "503 UNAVAILABLE": 1, "400 INVALID_ARGUMENT": 1 } },
  { ...base, id: 28, status: "cancelled", title: "Weekend photo walk — Kumartuli", body: "Meet at 7 am.",
    image_url: `${FIX}/tall-w900h1600.svg`, created_at: iso(-120 * H), updated_at: iso(-118 * H), scheduled_at: iso(-100 * H) },
];

const SCHEDULED = [
  { ...base, id: 33, status: "scheduled", title: "Golden Hour opens tomorrow", body: "Entries open at 9 am — be first.",
    image_url: `${FIX}/land-w1500h1000.svg`, scheduled_at: iso(14 * H), countdown_until: iso(38 * H),
    actions: [{ label: "Remind me", link: "/competitions" }], created_at: iso(-2 * H), updated_at: iso(-2 * H) },
  { ...base, id: 34, status: "scheduled", title: "Your weekly picks are ready", body: "12 photographs chosen for you.",
    image_url: null, link: "/feed", audience: { kind: "active", days: 7 }, scheduled_at: iso(62 * H), created_at: iso(-1 * H), updated_at: iso(-1 * H) },
];

const DRAFTS = [
  { ...base, id: 35, status: "draft", title: "New: private messages are coming", body: "", image_url: null, link: "/feed",
    created_at: iso(-5 * H), updated_at: iso(-3 * H) },
];

const TEMPLATES = [
  { ...base, id: 21, kind: "template", status: "draft", name: "Competition closing", title: "Monsoon Moods closes tonight",
    body: "Last chance to enter — the judges start tomorrow.", image_url: `${FIX}/land-w1500h1000.svg`,
    images: [`${FIX}/land-w1500h1000.svg`, `${FIX}/port-w1000h1250.svg`, `${FIX}/pano-w6000h1000.svg`],
    countdown_until: iso(30 * H + 25 * 60_000), link: "/competitions",
    actions: [{ label: "Enter now", link: "/competitions" }, { label: "See entries", link: "/competitions" }],
    created_at: iso(-400 * H), updated_at: iso(-30 * H) },
  { ...base, id: 22, kind: "template", status: "draft", name: "Winners", title: "Winners announced", body: "See the photographs the judges chose.",
    image_url: `${FIX}/port-w1000h1250.svg`, created_at: iso(-500 * H), updated_at: iso(-200 * H) },
];

export function sampleBroadcasts(body: Record<string, unknown>): unknown[] {
  const list = ({ history: ROWS, scheduled: SCHEDULED, drafts: DRAFTS, templates: TEMPLATES } as Record<string, unknown[]>)[String(body._view)] ?? [];
  return list.map((r) => ({ ...(r as object), total_count: list.length }));
}

export const sampleSendResult = (body: Record<string, unknown> | undefined) =>
  body?.test ? { success: true, test: true, devices: 1, sent: 1, removed: 0, errors: [] }
             : { success: true, sent: 52, failed: 2, removed: 2, devices: 54, members: 53 };

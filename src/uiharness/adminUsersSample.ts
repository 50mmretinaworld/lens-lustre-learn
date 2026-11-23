/**
 * Admin → Users sample (scene `screen-admin-users`). Synthetic members only —
 * no real member's name or e-mail. Switched on by the scene setting
 * `window.__harnessAdminUsers = true`; every other scene is unchanged.
 *
 * One population of 1,284 members feeds BOTH the current list
 * (admin_search_users_v3 + its user_roles / user_badges / profiles reads) and
 * the new table (admin_search_users_v4 + admin_user_facets), so the two
 * pictures show the same members.
 */
import { fixtureImage } from "./fixtures";

export const adminUsersSampleOn = () =>
  (globalThis as { __harnessAdminUsers?: boolean }).__harnessAdminUsers === true;

type Status = "active" | "suspended" | "banned" | "under_review" | "deletion_requested";

export interface SampleMember {
  id: string;
  email: string;
  full_name: string;
  avatar_url: string | null;
  custom_url: string | null;
  bio: string | null;
  created_at: string;
  last_active_at: string | null;
  last_platform: "app" | "web" | null;
  roles: string[];
  badges: string[];
  is_suspended: boolean;
  suspended_until: string | null;
  suspension_reason: string | null;
  is_banned: boolean;
  account_state: "active" | "under_review" | "deletion_requested";
  review_reason: string | null;
}

// Times are relative to the moment the picture is taken, so "5 min ago" reads as 5 min ago (there is no fake clock).
const NOW = Date.now();
const iso = (msAgo: number) => new Date(NOW - msAgo).toISOString();
const H = 3_600_000;
const D = 24 * H;
const uid = (n: number) => `a0000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

/** The first twelve are hand-written so every state is on page 1. */
const HAND: Omit<SampleMember, "id">[] = [
  { email: "ritika.sen@example.com", full_name: "Ritika Sen", avatar_url: fixtureImage(1), custom_url: "ritikasen", bio: "Street, Kolkata.", created_at: iso(2 * H), last_active_at: iso(5 * 60_000), last_platform: "app", roles: ["user"], badges: [], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "active", review_reason: null },
  { email: "arjun.mehta@example.com", full_name: "Arjun Mehta", avatar_url: null, custom_url: "arjunm", bio: null, created_at: iso(9 * H), last_active_at: iso(3 * H), last_platform: "web", roles: ["user", "registered_photographer"], badges: ["top_contributor"], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "active", review_reason: null },
  { email: "spam.seller88@example.com", full_name: "Lens Deals Store", avatar_url: null, custom_url: null, bio: "Cheap lenses, DM", created_at: iso(1 * D), last_active_at: iso(1 * D), last_platform: "web", roles: ["user"], badges: [], is_suspended: true, suspended_until: null, suspension_reason: "Spam links in comments", is_banned: true, account_state: "active", review_reason: null },
  { email: "priya.nair@example.com", full_name: "Priya Nair", avatar_url: fixtureImage(2), custom_url: "priyanair", bio: "Portraits.", created_at: iso(2 * D), last_active_at: iso(20 * H), last_platform: "app", roles: ["user", "judge"], badges: ["featured"], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "active", review_reason: null },
  { email: "copycat.photo@example.com", full_name: "Rohan Das", avatar_url: null, custom_url: "rohandas", bio: null, created_at: iso(3 * D), last_active_at: iso(2 * D), last_platform: "app", roles: ["user"], badges: [], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "active", review_reason: null },
  { email: "kavya.iyer@example.com", full_name: "Kavya Iyer", avatar_url: fixtureImage(4), custom_url: "kavyaiyer", bio: null, created_at: iso(4 * D), last_active_at: iso(4 * D), last_platform: "web", roles: ["user"], badges: [], is_suspended: true, suspended_until: iso(-5 * D), suspension_reason: "Abusive comments", is_banned: false, account_state: "active", review_reason: null },
  { email: "imran.k@example.com", full_name: "Imran Khan", avatar_url: null, custom_url: "imrank", bio: null, created_at: iso(6 * D), last_active_at: iso(6 * D), last_platform: "app", roles: ["user"], badges: [], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "under_review", review_reason: "Copied photos reported by three members" },
  { email: "sneha.b@example.com", full_name: "Sneha Banerjee", avatar_url: fixtureImage(5), custom_url: "snehab", bio: null, created_at: iso(8 * D), last_active_at: iso(7 * D), last_platform: "app", roles: ["user", "student"], badges: [], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "deletion_requested", review_reason: "Member asked to delete the account" },
  { email: "editor.team@example.com", full_name: "Meera Joshi", avatar_url: fixtureImage(6), custom_url: "meerajoshi", bio: null, created_at: iso(12 * D), last_active_at: iso(30 * 60_000), last_platform: "web", roles: ["user", "content_editor"], badges: [], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "active", review_reason: null },
  { email: "old.member@example.com", full_name: "Subhas Ghosh", avatar_url: null, custom_url: null, bio: null, created_at: iso(140 * D), last_active_at: iso(120 * D), last_platform: null, roles: ["user"], badges: [], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "active", review_reason: null },
  { email: "vikram.r@example.com", full_name: "Vikram Rao", avatar_url: fixtureImage(7), custom_url: "vikramrao", bio: null, created_at: iso(20 * D), last_active_at: iso(10 * D), last_platform: "web", roles: ["user"], badges: [], is_suspended: true, suspended_until: null, suspension_reason: "Repeated fake entries in a contest", is_banned: false, account_state: "under_review", review_reason: "Contest entries under check" },
  { email: "admin@example.com", full_name: "50mm Retina World", avatar_url: fixtureImage(8), custom_url: "50mmretinaworld", bio: null, created_at: iso(300 * D), last_active_at: iso(2 * 60_000), last_platform: "web", roles: ["user", "admin"], badges: ["featured"], is_suspended: false, suspended_until: null, suspension_reason: null, is_banned: false, account_state: "active", review_reason: null },
];

const FIRST = ["Aditi", "Rahul", "Ananya", "Sourav", "Neha", "Karan", "Pooja", "Amit", "Isha", "Debashis", "Riya", "Sanjay", "Tanya", "Nikhil", "Moumita", "Varun"];
const LAST = ["Roy", "Sharma", "Chatterjee", "Gupta", "Bose", "Pillai", "Verma", "Mukherjee", "Reddy", "Saha", "Kapoor", "Dutta"];
const TOTAL = 1284;

let cache: SampleMember[] | null = null;
export function sampleMembers(): SampleMember[] {
  if (cache) return cache;
  const out: SampleMember[] = HAND.map((m, i) => ({ id: uid(i + 1), ...m }));
  for (let i = out.length; i < TOTAL; i++) {
    const f = FIRST[i % FIRST.length];
    const l = LAST[(i * 7) % LAST.length];
    const age = (14 + i * 0.27) * D;
    const platform = i % 5 === 0 ? null : i % 3 === 0 ? "web" : "app";
    const suspended = i % 211 === 0;
    out.push({
      id: uid(i + 1),
      email: `${f}.${l}${i}@example.com`.toLowerCase(),
      full_name: `${f} ${l}`,
      avatar_url: i % 4 === 0 ? fixtureImage(i % 9) : null,
      custom_url: i % 6 === 0 ? null : `${f}${l}${i}`.toLowerCase(),
      bio: null,
      created_at: iso(age),
      last_active_at: platform === null && i % 2 === 0 ? null : iso(Math.min(age, (i % 40) * D + (i % 11) * H)),
      last_platform: platform,
      roles: i % 9 === 0 ? ["user", "registered_photographer"] : ["user"],
      badges: i % 37 === 0 ? ["top_contributor"] : [],
      is_suspended: suspended,
      suspended_until: suspended ? iso(-10 * D) : null,
      suspension_reason: suspended ? "Spam" : null,
      is_banned: false,
      account_state: i % 401 === 0 ? "under_review" : "active",
      review_reason: i % 401 === 0 ? "Reported by members" : null,
    });
  }
  cache = out;
  return out;
}

/** One status per member, same order as admin_search_users_v4. */
export function statusOf(m: SampleMember): Status {
  if (m.is_banned) return "banned";
  if (m.is_suspended) return "suspended";
  if (m.account_state === "deletion_requested") return "deletion_requested";
  if (m.account_state === "under_review") return "under_review";
  return "active";
}

const str = (v: unknown) => (typeof v === "string" ? v : "");

function matches(m: SampleMember, b: Record<string, unknown>, skip: "status" | "platform" | null): boolean {
  const q = str(b._query).trim().toLowerCase();
  const by = str(b._by);
  if (q) {
    const name = m.full_name.toLowerCase();
    const email = m.email.toLowerCase();
    const handle = (m.custom_url ?? "").toLowerCase();
    const hit = by === "email" ? email.includes(q) : by === "name" ? name.includes(q) : name.includes(q) || email.includes(q) || handle.includes(q);
    if (!hit) return false;
  }
  if (str(b._role) && !m.roles.includes(str(b._role))) return false;
  if (str(b._badge) && !m.badges.includes(str(b._badge))) return false;
  const platform = str(b._platform);
  if (skip !== "platform" && platform) {
    if (platform === "unknown" ? m.last_platform !== null : m.last_platform !== platform) return false;
  }
  const status = str(b._status);
  if (skip !== "status" && status && statusOf(m) !== status) return false;
  const active = str(b._active);
  if (active) {
    const t = m.last_active_at ? Date.parse(m.last_active_at) : 0;
    if (active === "24h" && NOW - t > D) return false;
    if (active === "7d" && NOW - t > 7 * D) return false;
    if (active === "30d" && NOW - t > 30 * D) return false;
    if (active === "inactive90" && t && NOW - t <= 90 * D) return false;
  }
  return true;
}

function sorted(rows: SampleMember[], sort: string): SampleMember[] {
  const by = {
    joined_desc: (a: SampleMember, b: SampleMember) => b.created_at.localeCompare(a.created_at),
    joined_asc: (a: SampleMember, b: SampleMember) => a.created_at.localeCompare(b.created_at),
    name_asc: (a: SampleMember, b: SampleMember) => a.full_name.localeCompare(b.full_name),
    name_desc: (a: SampleMember, b: SampleMember) => b.full_name.localeCompare(a.full_name),
    active_desc: (a: SampleMember, b: SampleMember) => (b.last_active_at ?? "").localeCompare(a.last_active_at ?? ""),
    active_asc: (a: SampleMember, b: SampleMember) => (a.last_active_at ?? "~").localeCompare(b.last_active_at ?? "~"),
  }[sort] ?? ((a: SampleMember, b: SampleMember) => b.created_at.localeCompare(a.created_at));
  return [...rows].sort(by);
}

const page = (rows: SampleMember[], b: Record<string, unknown>, def: number) => {
  const limit = Math.min(Math.max(Number(b._limit ?? def) || def, 1), 200);
  const offset = Math.max(Number(b._offset ?? 0) || 0, 0);
  return rows.slice(offset, offset + limit);
};

/** admin_search_users_v3 — the CURRENT list's rows (no roles/activity: it reads those separately). */
export function sampleSearchV3(b: Record<string, unknown>) {
  const all = sampleMembers().filter((m) => matches(m, { ...b, _by: str(b._by) || "name" }, "status"));
  return page(sorted(all, "joined_desc"), b, 100).map((m) => ({
    id: m.id, email: m.email, full_name: m.full_name, avatar_url: m.avatar_url, bio: m.bio,
    is_suspended: m.is_suspended, suspended_until: m.suspended_until, suspension_reason: m.suspension_reason,
    created_at: m.created_at, total_count: all.length,
  }));
}

export function samplePlatformCounts(b: Record<string, unknown>) {
  const all = sampleMembers().filter((m) => matches(m, { ...b, _platform: "", _by: str(b._by) || "name" }, "status"));
  return [{
    all_count: all.length,
    app_count: all.filter((m) => m.last_platform === "app").length,
    web_count: all.filter((m) => m.last_platform === "web").length,
    unknown_count: all.filter((m) => m.last_platform === null).length,
  }];
}

/** admin_search_users_v4 — everything the new table shows, in one call. */
export function sampleSearchV4(b: Record<string, unknown>) {
  const all = sampleMembers().filter((m) => matches(m, b, null));
  return page(sorted(all, str(b._sort) || "joined_desc"), b, 50).map((m) => ({
    id: m.id, email: m.email, full_name: m.full_name, avatar_url: m.avatar_url, custom_url: m.custom_url, bio: m.bio,
    created_at: m.created_at, last_active_at: m.last_active_at, last_platform: m.last_platform,
    roles: m.roles, badges: m.badges, status: statusOf(m),
    suspended_until: m.suspended_until, suspension_reason: m.suspension_reason, review_reason: m.review_reason,
    total_count: all.length,
  }));
}

/** admin_user_facets — status counts (all filters but status) + platform counts (all filters but platform). */
export function sampleFacets(b: Record<string, unknown>) {
  const s = sampleMembers().filter((m) => matches(m, b, "status"));
  const p = sampleMembers().filter((m) => matches(m, b, "platform"));
  const n = (st: Status) => s.filter((m) => statusOf(m) === st).length;
  return [{
    all_count: s.length, active_count: n("active"), suspended_count: n("suspended"), banned_count: n("banned"),
    under_review_count: n("under_review"), deletion_requested_count: n("deletion_requested"),
    platform_all_count: p.length,
    app_count: p.filter((m) => m.last_platform === "app").length,
    web_count: p.filter((m) => m.last_platform === "web").length,
    unknown_count: p.filter((m) => m.last_platform === null).length,
  }];
}

/** Rows the CURRENT list reads from tables after the RPC. */
export const sampleUserRoles = () => sampleMembers().flatMap((m) => m.roles.map((role) => ({ user_id: m.id, role })));
export const sampleUserBadges = () => sampleMembers().flatMap((m) => m.badges.map((badge_type) => ({ user_id: m.id, badge_type })));
export const sampleProfiles = () => sampleMembers().map((m) => ({ id: m.id, full_name: m.full_name, avatar_url: m.avatar_url, custom_url: m.custom_url, last_active_at: m.last_active_at, last_platform: m.last_platform }));

export const sampleRoleDefinitions = [
  { role_key: "admin", label: "Admin", icon: "🛡️", pill_class: "bg-destructive/10 text-destructive border-destructive/30", show_inline: true, sort_order: 1 },
  { role_key: "judge", label: "Jury", icon: "⚖️", pill_class: "bg-violet-500/10 text-violet-700 border-violet-500/30 dark:text-violet-300", show_inline: true, sort_order: 2 },
  { role_key: "content_editor", label: "Contributor", icon: "✍️", pill_class: "bg-sky-500/10 text-sky-700 border-sky-500/30 dark:text-sky-300", show_inline: true, sort_order: 3 },
  { role_key: "registered_photographer", label: "Photographer", icon: "📷", pill_class: "bg-emerald-500/10 text-emerald-700 border-emerald-500/30 dark:text-emerald-300", show_inline: true, sort_order: 4 },
  { role_key: "student", label: "Student", icon: "🎓", pill_class: "bg-amber-500/10 text-amber-700 border-amber-500/30 dark:text-amber-300", show_inline: true, sort_order: 5 },
  { role_key: "user", label: "User", icon: "", pill_class: "bg-muted text-muted-foreground border-border", show_inline: false, sort_order: 6 },
];
// ── M34 app versions (SQL 4400): admin_member_apps · admin_app_versions · admin_app_version_members ──
// Android 1.2.56 newest, then 1.2.55 / 1.2.54 / 1.2.52 / 1.2.50, older Android app without a version (token only, or
// only profiles.last_platform = 'app'), iPhone 1.1, website only — answered with the same rule as member_app_rows.

type SampleApp = { os: "android" | "ios"; version: string | null; seen_at: string; push: "on" | "off" } | null;
const HAND_APP: Record<number, [("android" | "ios"), string | null]> = {
  0: ["android", "1.2.56"], 3: ["ios", "1.1"], 4: ["android", "1.2.52"], 6: ["android", null], 7: ["android", "1.2.55"],
};
const SPREAD: ([("android" | "ios"), string | null] | "profile-only")[] = [
  ["android", "1.2.56"], ["android", "1.2.56"], ["android", "1.2.56"], ["android", "1.2.56"], ["android", "1.2.56"],
  ["android", "1.2.56"], ["android", "1.2.56"], ["android", "1.2.55"], ["android", "1.2.55"], ["android", "1.2.55"],
  ["android", "1.2.54"], ["android", "1.2.54"], ["android", "1.2.52"], ["android", "1.2.50"], ["ios", "1.1"],
  ["ios", "1.1"], ["android", null], ["android", null], "profile-only", ["android", "1.2.56"],
];

let appCache: Map<string, SampleApp> | null = null;
/** Which app each sample member is on (null = no app record). */
export function sampleApps(): Map<string, SampleApp> {
  if (appCache) return appCache;
  const out = new Map<string, SampleApp>();
  sampleMembers().forEach((m, i) => {
    if (m.last_platform !== "app") { out.set(m.id, null); return; }
    const pick = i < HAND.length ? HAND_APP[i] ?? "profile-only" : SPREAD[Math.floor(i / 3) % SPREAD.length];
    if (pick === "profile-only") { out.set(m.id, null); return; }
    out.set(m.id, { os: pick[0], version: pick[1], seen_at: m.last_active_at ?? m.created_at, push: i % 7 === 3 ? "off" : "on" });
  });
  appCache = out;
  return out;
}

export function sampleMemberApps(b: Record<string, unknown>) {
  const ids = Array.isArray(b._ids) ? (b._ids as unknown[]).filter((x): x is string => typeof x === "string") : [];
  const apps = sampleApps();
  return ids.flatMap((id) => {
    const a = apps.get(id);
    return a ? [{ user_id: id, os: a.os, app_version: a.version, seen_at: a.seen_at, push: a.push }] : [];
  });
}

const week = (iso: string | null) => !!iso && NOW - Date.parse(iso) < 7 * D;

export function sampleAppVersions() {
  const apps = sampleApps();
  const v = new Map<string, { os: string; version: string; members: number; active_7d: number; last_seen: string }>();
  let older = 0, older7 = 0, web = 0, web7 = 0, none = 0;
  for (const m of sampleMembers()) {
    const a = apps.get(m.id);
    if (a && a.version) {
      const k = `${a.os}|${a.version}`;
      const row = v.get(k) ?? { os: a.os, version: a.version, members: 0, active_7d: 0, last_seen: a.seen_at };
      row.members++; if (week(a.seen_at)) row.active_7d++;
      if (a.seen_at > row.last_seen) row.last_seen = a.seen_at;
      v.set(k, row);
    } else if (a || m.last_platform === "app") {
      older++; if (week(a ? a.seen_at : m.last_active_at)) older7++;
    } else if (m.last_platform === "web") {
      web++; if (week(m.last_active_at)) web7++;
    } else none++;
  }
  return {
    checked_at: new Date(NOW).toISOString(),
    versions: [...v.values()].sort((x, y) => x.os.localeCompare(y.os) || y.members - x.members),
    older_app: { members: older, active_7d: older7 },
    website_only: { members: web, active_7d: web7 },
    not_recorded: none,
    total: sampleMembers().length,
  };
}

export function sampleAppVersionMembers(b: Record<string, unknown>) {
  const os = str(b._os);
  const version = str(b._version) || null;
  const apps = sampleApps();
  const picked = sampleMembers().flatMap((m) => {
    const a = apps.get(m.id);
    const hit = os === "android" || os === "ios" ? !!a && a.os === os && a.version === version
      : os === "older" ? (!!a && a.version === null) || (!a && m.last_platform === "app")
      : os === "web" ? !a && m.last_platform === "web" : false;
    return hit ? [{ m, os: a?.os ?? null, version: a?.version ?? null, seen: a ? a.seen_at : m.last_active_at }] : [];
  }).sort((x, y) => (y.seen ?? "").localeCompare(x.seen ?? ""));
  const limit = Math.min(Math.max(Number(b._limit ?? 100) || 100, 1), 200);
  const offset = Math.max(Number(b._offset ?? 0) || 0, 0);
  return picked.slice(offset, offset + limit).map((p) => ({
    id: p.m.id, full_name: p.m.full_name, avatar_url: p.m.avatar_url, custom_url: p.m.custom_url,
    os: p.os, app_version: p.version, seen_at: p.seen, total_count: picked.length,
  }));
}

export const sampleBadgeDefinitions = [
  { type_key: "featured", label: "Featured", icon: "⭐", badge_class: "bg-amber-500/15 text-amber-700 border-amber-500/30", ribbon_class: "bg-gradient-to-r from-amber-500 to-yellow-400", is_active: true, sort_order: 1 },
  { type_key: "top_contributor", label: "Top contributor", icon: "🏅", badge_class: "bg-orange-500/15 text-orange-700 border-orange-500/30", ribbon_class: "bg-gradient-to-r from-orange-500 to-red-400", is_active: true, sort_order: 2 },
];

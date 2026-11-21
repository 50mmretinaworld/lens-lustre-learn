/**
 * M8b harness sample — what the Messages admin rpcs answer, shaped like the launch
 * state: "Only people on my list", the Owner alone on the list, groups off, the
 * English starter word list (a few rows), three open reports, a watch list, one member with rules.
 * Only answers when __harnessAdminMessages is set (scenes screen-admin-messages*).
 */
export function adminMessagesSampleOn(): boolean {
  return (globalThis as { __harnessAdminMessages?: boolean }).__harnessAdminMessages === true;
}

const OWNER = "11111111-1111-4111-8111-111111111111";
const SOMNATH = "22222222-2222-4222-8222-222222222222";
const FRAMO = "33333333-3333-4333-8333-333333333333";
const CONV_HELD = "aaaaaaaa-0000-4000-8000-0000000000a1";
const CONV_2 = "aaaaaaaa-0000-4000-8000-0000000000a2";
const t = (minAgo: number) => new Date(Date.UTC(2026, 10, 21, 9, 30) - minAgo * 60_000).toISOString();

export function sampleMessageAdminState() {
  return {
    mode: "allowed_selected",
    groups_enabled: false,
    updated_at: t(600),
    members: [{ user_id: OWNER, full_name: "Neil Basu", username: "neilbasu", avatar_url: null, listed_at: t(600), note: "Launch: Owner only" }],
    rules: [{
      user_id: SOMNATH, full_name: "Somnath Roy", text_ok: true, photos_ok: false, groups_ok: true, friends_only: true,
      daily_limit: 20, blocked_until: null, reason: "New account, watching for a week", set_at: t(120),
    }],
    log: [
      { at: t(120), actor: OWNER, area: "member_rule", user_id: SOMNATH, old: "default", new: "text=true photos=false groups=true friends_only=true limit=20 until=-", reason: "New account, watching for a week" },
      { at: t(600), actor: OWNER, area: "list", user_id: OWNER, old: "not listed", new: "listed", reason: "Launch: Owner only" },
      { at: t(610), actor: OWNER, area: "mode", user_id: null, old: "blocked_all", new: "allowed_selected", reason: "Start with the Owner alone, 48 hours watched" },
    ],
  };
}

const w = (id: number, category: string, pattern: string, action: string, active = true) =>
  ({ id, category, pattern, lang: "en", action, active, added_at: t(5000) });

export function sampleWordRules() {
  return [
    w(1, "abuse", "idiot", "block"), w(2, "abuse", "bastard", "block"), w(3, "abuse", "scum", "block", false),
    w(4, "threat", "i will kill you", "block"), w(5, "threat", "i will find you", "block"),
    w(6, "political", "election", "block", false), w(7, "political", "bjp", "block", false),
    w(8, "abnormal", "send nudes", "block"),
    w(9, "self_harm", "suicide", "help"), w(10, "self_harm", "want to die", "help"),
  ];
}

export function sampleReports() {
  return [
    { id: 12, status: "open", reason: "abuse", note: "He keeps sending rude replies on my photos.", created_at: t(42), conversation_id: CONV_HELD,
      reporter_id: SOMNATH, reporter_name: "Somnath Roy", reported_id: FRAMO, reported_name: "Framo Grapher", reports_30d: 3, handled_at: null, handled_note: null },
    { id: 11, status: "open", reason: "spam", note: null, created_at: t(300), conversation_id: CONV_2,
      reporter_id: OWNER, reporter_name: "Neil Basu", reported_id: FRAMO, reported_name: "Framo Grapher", reports_30d: 3, handled_at: null, handled_note: null },
    { id: 10, status: "open", reason: "nudity", note: null, created_at: t(1700), conversation_id: CONV_2,
      reporter_id: FRAMO, reporter_name: "Framo Grapher", reported_id: SOMNATH, reported_name: "Somnath Roy", reports_30d: 1, handled_at: null, handled_note: null },
  ];
}

export function sampleWatchlist() {
  return [
    { user_id: FRAMO, full_name: "Framo Grapher", username: "framo", avatar_url: null, reports_30d: 3, open_reports: 2, reporters: 2, last_report_at: t(42), paused: false },
    { user_id: SOMNATH, full_name: "Somnath Roy", username: "somnath", avatar_url: null, reports_30d: 1, open_reports: 1, reporters: 1, last_report_at: t(1700), paused: true },
  ];
}

type SampleMember = {
  user_id: string; full_name: string; username: string; avatar_url: null; email: string; joined_at: string;
  chats: number; last_message_at: string | null; reports_30d: number; listed: boolean; paused: boolean; has_rules: boolean; is_admin: boolean;
};
const mem = (n: number, full_name: string, username: string, o: Partial<SampleMember> = {}): SampleMember => ({
  user_id: `44444444-4444-4444-8444-${String(n).padStart(12, "0")}`, full_name, username, avatar_url: null,
  email: `${username}@example.test`, joined_at: t(60 * 24 * (20 + n * 9)), chats: 0, last_message_at: null, reports_30d: 0,
  listed: false, paused: false, has_rules: false, is_admin: false, ...o,
});
const MEMBERS: SampleMember[] = [
  mem(1, "Neil Basu", "neilbasu", { user_id: OWNER, chats: 6, last_message_at: t(42), listed: true, is_admin: true }),
  mem(2, "Somnath Roy", "somnath", { user_id: SOMNATH, chats: 4, last_message_at: t(95), reports_30d: 1, paused: true, has_rules: true }),
  mem(3, "Framo Grapher", "framo", { user_id: FRAMO, chats: 9, last_message_at: t(20), reports_30d: 3 }),
  mem(4, "Ananya Sen", "ananya.sen", { chats: 12, last_message_at: t(8) }),
  mem(5, "Rakesh Dutta", "rakeshd", { chats: 3, last_message_at: t(1500) }),
  mem(6, "Priya Nair", "priyanair", { chats: 7, last_message_at: t(300), reports_30d: 1 }),
  mem(7, "Imran Qureshi", "imranq", { chats: 1, last_message_at: t(4300) }),
  mem(8, "Sandeep Kale", "sandeepk", { chats: 5, last_message_at: t(180), has_rules: true }),
  mem(9, "Meera Iyer", "meera.iyer", { chats: 0 }),
  mem(10, "Tanmay Ghosh", "tanmayg", { chats: 2, last_message_at: t(9000) }),
  mem(11, "Lakshmi Rao", "lakshmirao", { chats: 0 }),
  mem(12, "Arjun Mehta", "arjunm", { chats: 8, last_message_at: t(60), listed: true }),
];

/** The latest chats of a member, as the SQL returns them: the OTHER person of each (up to 3). */
const withOf = (m: SampleMember) => MEMBERS.filter((o) => o.user_id !== m.user_id).slice(m.chats % 5, (m.chats % 5) + Math.min(3, m.chats))
  .map((o) => ({ kind: "direct", user_id: o.user_id, name: o.full_name, avatar_url: null }));

/** What admin_message_member_search answers: search, filter, sort and paging done here as the SQL does them. */
export function sampleMemberSearch(b: Record<string, unknown>) {
  const needle = String(b._q ?? "").trim().toLowerCase();
  const filter = String(b._filter ?? "all");
  const sort = String(b._sort ?? "name");
  const desc = String(b._dir ?? "asc") === "desc";
  const lim = Number(b._limit ?? 25);
  const off = Number(b._offset ?? 0);
  const base = MEMBERS.filter((m) => !needle || `${m.full_name} ${m.username} ${m.email}`.toLowerCase().includes(needle));
  const shown = base.filter((m) => (filter === "active" ? m.chats > 0 : filter === "reported" ? m.reports_30d > 0 : filter === "paused" ? m.paused : filter === "listed" ? m.listed : true));
  const key = (m: SampleMember): string | number => (sort === "chats" ? m.chats : sort === "reports" ? m.reports_30d : sort === "joined" ? Date.parse(m.joined_at)
    : sort === "last" ? (m.last_message_at ? Date.parse(m.last_message_at) : -1) : m.full_name.toLowerCase());
  const sorted = [...shown].sort((a, c) => (key(a) < key(c) ? -1 : key(a) > key(c) ? 1 : 0) * (desc ? -1 : 1));
  return {
    total: shown.length,
    counts: {
      all: base.length, active: base.filter((m) => m.chats > 0).length, reported: base.filter((m) => m.reports_30d > 0).length,
      paused: base.filter((m) => m.paused).length, listed: base.filter((m) => m.listed).length,
    },
    rows: sorted.slice(off, off + lim).map((m) => ({ ...m, chatting_with: withOf(m) })),
  };
}

export function sampleProfileSearch() {
  return [
    { id: SOMNATH, full_name: "Somnath Roy", email: "somnath@example.test", avatar_url: null },
    { id: FRAMO, full_name: "Framo Grapher", email: "framo@example.test", avatar_url: null },
  ];
}

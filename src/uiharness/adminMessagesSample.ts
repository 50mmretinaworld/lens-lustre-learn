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

export function sampleMemberChats() {
  return [
    { conversation_id: CONV_HELD, kind: "direct", title: null, last_message_at: t(42), messages: 14, others: [{ user_id: FRAMO, full_name: "Framo Grapher", username: "framo" }] },
    { conversation_id: CONV_2, kind: "direct", title: null, last_message_at: t(1500), messages: 6, others: [{ user_id: SOMNATH, full_name: "Somnath Roy", username: "somnath" }] },
  ];
}

export function sampleReadConversation() {
  return {
    conversation_id: CONV_HELD,
    members: [
      { user_id: OWNER, full_name: "Neil Basu", username: "neilbasu", folder: "inbox" },
      { user_id: FRAMO, full_name: "Framo Grapher", username: "framo", folder: "inbox" },
    ],
    messages: [
      { id: 501, sender_id: FRAMO, kind: "text", body: "Did you see the election results? Tell me what you think about the BJP win.", status: "sent", created_at: t(42), photos: [] },
      { id: 500, sender_id: OWNER, kind: "text", body: "Thanks for the sunset frames. The second one is my favourite.", status: "sent", created_at: t(95), photos: [] },
      { id: 499, sender_id: FRAMO, kind: "text", body: "Shot them at Digha on Sunday, 50mm at f/1.8.", status: "sent", created_at: t(130), photos: [] },
    ],
  };
}

export function sampleProfileSearch() {
  return [
    { id: SOMNATH, full_name: "Somnath Roy", email: "somnath@example.test", avatar_url: null },
    { id: FRAMO, full_name: "Framo Grapher", email: "framo@example.test", avatar_url: null },
  ];
}

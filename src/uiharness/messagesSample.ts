/**
 * UI harness — Messages sample (scenes screen-messages, screen-message-thread, screen-message-request).
 * Synthetic members from fixtures.ts; times are "minutes ago" from now so the list reads naturally.
 * Only answers when __harnessMessages is set. Photo paths are data: swatches — signedPhotoUrl passes a data:
 * path straight through (never a real storage path), so the picture renders with no network.
 */
import { HARNESS_USER_ID, fixtureImage, profiles } from "./fixtures";

export function messagesSampleOn(): boolean {
  return (globalThis as { __harnessMessages?: boolean }).__harnessMessages === true;
}

/** ?sendoff=1 → the member may read but not send; ?help=1 → the next send answers with the helpline flag. */
export const messagesFlag = (name: string): boolean =>
  typeof location !== "undefined" && new URLSearchParams(location.search).get(name) === "1";

const ago = (min: number) => new Date(Date.now() - min * 60_000).toISOString();
const person = (i: number) => {
  const p = profiles[i % profiles.length];
  return { user_id: p.id, full_name: p.full_name, username: p.custom_url, avatar_url: p.avatar_url };
};

export const CONV = {
  ranjana: "aaaaaaaa-0000-4000-8000-000000000001",
  liwei: "aaaaaaaa-0000-4000-8000-000000000002",
  official: "aaaaaaaa-0000-4000-8000-000000000003",
  stranger: "aaaaaaaa-0000-4000-8000-000000000004",
};

const inbox = () => [
  { conversation_id: CONV.ranjana, kind: "direct", title: null, folder: "inbox", muted: false, last_message_at: ago(12), other: person(1),
    last: { id: 106, sender_id: profiles[1].id, kind: "text", body: "Loved the frame from Sunday — which lens was that?", created_at: ago(12) }, unread: 2 },
  { conversation_id: CONV.liwei, kind: "direct", title: null, folder: "inbox", muted: false, last_message_at: ago(190), other: person(2),
    last: { id: 91, sender_id: HARNESS_USER_ID, kind: "text", body: "Sure, see you at the walk on Saturday", created_at: ago(190) }, unread: 0 },
  { conversation_id: CONV.official, kind: "direct", title: null, folder: "inbox", muted: false, last_message_at: ago(1500),
    other: { user_id: "00000000-0000-4000-8000-0000000000aa", full_name: "50mm Retina World", username: "50mm", avatar_url: null },
    last: { id: 70, sender_id: "00000000-0000-4000-8000-0000000000aa", kind: "text", body: "Welcome to private messages. Be kind, keep it respectful.", created_at: ago(1500) }, unread: 0 },
];
const requests = () => [
  { conversation_id: CONV.stranger, kind: "direct", title: null, folder: "requests", muted: false, last_message_at: ago(45), other: person(3),
    last: { id: 120, sender_id: profiles[3 % profiles.length].id, kind: "text", body: "Hi! Big fan of your portraits — can I ask about your editing?", created_at: ago(45) }, unread: 1 },
];

export function sampleConversations(body: Record<string, unknown>): unknown[] {
  return body._folder === "requests" ? requests() : inbox();
}
export const sampleUnread = () => ({ inbox: 2, requests: 1 });

export function sampleThread(body: Record<string, unknown>): unknown[] {
  const id = String(body._conversation ?? "");
  const them = id === CONV.stranger ? profiles[3 % profiles.length].id : profiles[1].id;
  const m = (mid: number, sender: string, text: string, min: number, extra: Record<string, unknown> = {}) =>
    ({ id: mid, sender_id: sender, kind: "text", body: text, created_at: ago(min), status: "sent", photos: [], ...extra });
  if (id === CONV.stranger) {
    return [m(120, them, "Hi! Big fan of your portraits — can I ask about your editing?", 45)];
  }
  return [
    m(106, them, "Loved the frame from Sunday — which lens was that?", 12),
    m(105, them, "The light on her face is unreal", 13),
    m(104, HARNESS_USER_ID, "", 30, { kind: "photo", photos: [{ path: fixtureImage(11, "50mm f/1.4"), width: 900, height: 600 }] }),
    m(103, HARNESS_USER_ID, "Thank you! Shot at golden hour, mostly natural light.", 31),
    m(102, them, "Hey! Saw your latest post. Are you free this weekend for a photo walk?", 60),
    m(101, HARNESS_USER_ID, "Waiting for review", 62, { status: "held", body: "Which party are you voting for in the election?" }),
  ];
}

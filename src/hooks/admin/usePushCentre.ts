/**
 * PUSH CENTRE (PN3) — the admin page's one data layer.
 *
 * Every read and write goes through the 20261116_1500 RPCs (admin-gated in
 * SQL) and the send-broadcast-push edge function. Nothing here decides who
 * receives a push: the audience is resolved on the server, the same way for
 * the count the admin sees and for the send itself.
 *
 * Contract pinned against the SQL file by
 * src/hooks/admin/__tests__/usePushCentre.test.ts.
 */
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { queryKeys } from "@/lib/queryKeys";

export type PushAudience =
  | { kind: "all" }
  | { kind: "active"; days: 7 | 30 }
  | { kind: "role"; role: string }
  | { kind: "badge"; badge: string }
  | { kind: "members"; ids: string[] };

export interface PushAction { label: string; link: string }

export interface PushDraft {
  id: number | null;
  kind: "message" | "template";
  name: string;
  title: string;
  body: string;
  image_url: string;
  images: string[];
  link: string;
  /** ISO time or "" */
  countdown_until: string;
  actions: PushAction[];
  audience: PushAudience;
}

export const EMPTY_DRAFT: PushDraft = {
  id: null, kind: "message", name: "", title: "", body: "", image_url: "", images: [], link: "",
  countdown_until: "", actions: [], audience: { kind: "all" },
};

export interface PushAudienceCount {
  matched: number;
  held: number;
  eligible: number;
  reachable_members: number;
  devices: number;
  rich_devices: number;
  said_no: number;
  app_recent_no_phone: number;
  app_old_no_phone: number;
  website_only: number;
  scheduling_on: boolean;
}

export type PushView = "history" | "scheduled" | "drafts" | "templates";
export type PushStatus = "draft" | "scheduled" | "sending" | "sent" | "failed" | "cancelled";

export interface PushBroadcast {
  id: number;
  kind: "message" | "template";
  status: PushStatus;
  stuck: boolean;
  name: string | null;
  title: string;
  body: string;
  image_url: string | null;
  images: string[];
  link: string | null;
  countdown_until: string | null;
  actions: PushAction[];
  audience: PushAudience;
  scheduled_at: string | null;
  created_at: string;
  updated_at: string;
  started_at: string | null;
  finished_at: string | null;
  created_by_name: string | null;
  sent_by_name: string | null;
  audience_members: number | null;
  reached_members: number | null;
  devices: number | null;
  delivered: number;
  failed: number;
  removed: number;
  opened: number;
  fail_reasons: Record<string, number>;
}

/** Thrown when the 1500 functions are not on this database yet — the page shows the old box. */
export class PushRpcMissing extends Error {}

const num = (v: unknown): number => (typeof v === "number" ? v : Number(v ?? 0) || 0);
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : num(v));

function missing(err: { code?: string; message?: string } | null): boolean {
  return !!err && (err.code === "PGRST202" || err.code === "42883");
}

export function parseAudienceCount(rows: unknown): PushAudienceCount | null {
  const r = (Array.isArray(rows) ? rows[0] : rows) as Record<string, unknown> | undefined;
  if (!r) return null;
  return {
    matched: num(r.matched), held: num(r.held), eligible: num(r.eligible),
    reachable_members: num(r.reachable_members), devices: num(r.devices), rich_devices: num(r.rich_devices),
    said_no: num(r.said_no), app_recent_no_phone: num(r.app_recent_no_phone),
    app_old_no_phone: num(r.app_old_no_phone), website_only: num(r.website_only),
    scheduling_on: r.scheduling_on === true,
  };
}

export function parseBroadcasts(rows: unknown): { items: PushBroadcast[]; total: number } {
  const list = (Array.isArray(rows) ? rows : []) as Record<string, unknown>[];
  return {
    total: list.length ? num(list[0].total_count) : 0,
    items: list.map((r) => ({
      id: num(r.id),
      kind: r.kind === "template" ? "template" : "message",
      status: (r.status as PushStatus) ?? "draft",
      stuck: r.stuck === true,
      name: (r.name as string) ?? null,
      title: String(r.title ?? ""),
      body: String(r.body ?? ""),
      image_url: (r.image_url as string) ?? null,
      images: Array.isArray(r.images) ? (r.images as string[]) : [],
      link: (r.link as string) ?? null,
      countdown_until: (r.countdown_until as string) ?? null,
      actions: Array.isArray(r.actions) ? (r.actions as PushAction[]) : [],
      audience: (r.audience as PushAudience) ?? { kind: "all" },
      scheduled_at: (r.scheduled_at as string) ?? null,
      created_at: String(r.created_at ?? ""),
      updated_at: String(r.updated_at ?? ""),
      started_at: (r.started_at as string) ?? null,
      finished_at: (r.finished_at as string) ?? null,
      created_by_name: (r.created_by_name as string) ?? null,
      sent_by_name: (r.sent_by_name as string) ?? null,
      audience_members: numOrNull(r.audience_members),
      reached_members: numOrNull(r.reached_members),
      devices: numOrNull(r.devices),
      delivered: num(r.delivered), failed: num(r.failed), removed: num(r.removed), opened: num(r.opened),
      fail_reasons: (r.fail_reasons && typeof r.fail_reasons === "object" ? r.fail_reasons : {}) as Record<string, number>,
    })),
  };
}

/** Draft → the `_fields` object admin_push_broadcast_save takes. */
export function draftFields(d: PushDraft): Record<string, unknown> {
  return {
    kind: d.kind,
    name: d.name.trim(),
    title: d.title.trim(),
    body: d.body,
    image_url: d.image_url.trim(),
    images: d.images,
    link: d.link.trim(),
    countdown_until: d.countdown_until,
    actions: d.actions.filter((a) => a.label.trim() && a.link.trim()),
    audience: d.audience,
  };
}

export function broadcastToDraft(b: PushBroadcast, asNew = false): PushDraft {
  return {
    id: asNew ? null : b.id,
    kind: asNew ? "message" : b.kind,
    name: asNew ? "" : b.name ?? "",
    title: b.title, body: b.body, image_url: b.image_url ?? "", images: b.images, link: b.link ?? "",
    countdown_until: b.countdown_until ?? "", actions: b.actions, audience: b.audience,
  };
}

export function usePushAudience(audience: PushAudience) {
  return useQuery({
    queryKey: [...queryKeys.adminPush(), "audience", audience],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("admin_push_audience" as never, { _audience: audience } as never);
      if (missing(error)) throw new PushRpcMissing("admin_push_audience missing");
      if (error) throw error;
      return parseAudienceCount(data);
    },
    placeholderData: keepPreviousData,
    staleTime: 15_000,
    retry: (n, e) => !(e instanceof PushRpcMissing) && n < 2,
  });
}

export function usePushBroadcasts(view: PushView, page = 0, pageSize = 25) {
  return useQuery({
    queryKey: [...queryKeys.adminPush(), "list", view, page, pageSize],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("admin_push_broadcasts" as never,
        { _view: view, _limit: pageSize, _offset: page * pageSize } as never);
      if (missing(error)) throw new PushRpcMissing("admin_push_broadcasts missing");
      if (error) throw error;
      return parseBroadcasts(data);
    },
    placeholderData: keepPreviousData,
    // a sending broadcast fills in its numbers by itself
    refetchInterval: (q) => (q.state.data?.items.some((b) => b.status === "sending" || b.status === "scheduled") ? 10_000 : false),
    retry: (n, e) => !(e instanceof PushRpcMissing) && n < 2,
  });
}

export interface SendResult {
  success?: boolean;
  test?: boolean;
  skipped?: string;
  sent?: number;
  failed?: number;
  removed?: number;
  devices?: number;
  members?: number;
  note?: string;
  error?: string;
  errors?: string[];
}

/** Every write. Each returns { error } (a plain sentence) and refreshes the lists. */
export function usePushWrites() {
  const qc = useQueryClient();
  const refresh = () => qc.invalidateQueries({ queryKey: queryKeys.adminPush() });
  const say = (e: { message?: string } | null | undefined) => (e ? e.message || "Please try again" : null);

  const save = async (d: PushDraft): Promise<{ id: number | null; error: string | null }> => {
    const { data, error } = await supabase.rpc("admin_push_broadcast_save" as never,
      { _id: d.id, _fields: draftFields(d) } as never);
    void refresh();
    return { id: error ? null : num(data), error: say(error) };
  };

  const invoke = async (body: Record<string, unknown>): Promise<SendResult> => {
    const { data, error } = await supabase.functions.invoke("send-broadcast-push", { body });
    if (error) return { error: error.message || "Send failed" };
    return (data ?? {}) as SendResult;
  };

  /** Saves first, so what is tested is exactly what is stored. */
  const test = async (d: PushDraft): Promise<{ id: number | null; result: SendResult }> => {
    const s = await save(d);
    if (s.error || s.id === null) return { id: null, result: { error: s.error ?? "Could not save" } };
    return { id: s.id, result: await invoke({ broadcast_id: s.id, test: true }) };
  };

  /** at = null → now. A "now" send is also handed straight to the sender, so it never waits for the engine. */
  const schedule = async (d: PushDraft, at: string | null): Promise<{ id: number | null; result: SendResult }> => {
    const s = await save({ ...d, kind: "message" });
    if (s.error || s.id === null) return { id: null, result: { error: s.error ?? "Could not save" } };
    const { error } = await supabase.rpc("admin_push_broadcast_schedule" as never, { _id: s.id, _at: at } as never);
    if (error) {
      void refresh();
      return { id: s.id, result: { error: say(error) ?? "Could not schedule" } };
    }
    const result: SendResult = at === null ? await invoke({ broadcast_id: s.id }) : { success: true };
    void refresh();
    return { id: s.id, result };
  };

  const cancel = async (id: number) => {
    const { error } = await supabase.rpc("admin_push_broadcast_cancel" as never, { _id: id } as never);
    void refresh();
    return say(error);
  };

  const remove = async (id: number) => {
    const { error } = await supabase.rpc("admin_push_broadcast_delete" as never, { _id: id } as never);
    void refresh();
    return say(error);
  };

  return { save, test, schedule, cancel, remove };
}

/** "Everyone" · "Active in the last 7 days" · "Role: Judge" · "12 chosen members". */
export function audienceLabel(a: PushAudience, labelFor?: (kind: "role" | "badge", key: string) => string): string {
  switch (a.kind) {
    case "all": return "Everyone";
    case "active": return `Active in the last ${a.days} days`;
    case "role": return `Role: ${labelFor ? labelFor("role", a.role) : a.role}`;
    case "badge": return `Badge: ${labelFor ? labelFor("badge", a.badge) : a.badge}`;
    case "members": return `${a.ids.length} chosen member${a.ids.length === 1 ? "" : "s"}`;
  }
}

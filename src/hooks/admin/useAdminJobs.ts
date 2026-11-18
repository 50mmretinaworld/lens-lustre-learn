/**
 * J5a · Admin → Job Engine — READ ONLY.
 *
 * Two admin-only SECURITY DEFINER rpcs (20261118_0900); each checks
 * has_role(admin) itself, so the client never decides who may read:
 *   admin_jobs_overview()                              → switches, one row per job kind, open jobs:* alarms
 *   admin_jobs_list(_status, _kind, _limit, _before_id) → recent jobs, never their payload
 * No action here: a retry can send a push or an e-mail twice (separate unit).
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { queryKeys } from "@/lib/queryKeys";

type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
const rpc: Rpc = (fn, args) => (supabase.rpc as unknown as Rpc)(fn, args);

export type JobStatus = "queued" | "running" | "done" | "failed" | "cancelled";
const STATUSES: JobStatus[] = ["queued", "running", "done", "failed", "cancelled"];

export interface JobKindRow {
  kind: string;
  handler: string;
  enabled: boolean;
  max_running: number;
  max_attempts: number;
  timeout_seconds: number;
  running: number;
  queued: number;
  due: number;
  done_24h: number;
  failed_24h: number;
  avg_seconds_24h: number | null;
  last_done_at: string | null;
  last_failed_at: string | null;
  last_error: string | null;
}

export interface JobsAlarm {
  alarm_key: string;
  summary: string | null;
  opened_at: string;
  last_seen_at: string | null;
}

export interface JobsOverview {
  checked_at: string | null;
  switches: Record<string, boolean>;
  kinds: JobKindRow[];
  alarms: JobsAlarm[];
}

export interface JobRow {
  id: number;
  kind: string;
  status: JobStatus;
  attempts: number;
  max_attempts: number;
  run_at: string;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  last_error: string | null;
}

const str = (v: unknown) => (typeof v === "string" ? v : null);
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v)) ? Number(v) : null);
const obj = (v: unknown) => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null);

/** Shape guard: a malformed kind or alarm is dropped, never the page. */
export function parseJobsOverview(data: unknown): JobsOverview {
  const o = obj(data) ?? {};
  const sw = obj(o.switches) ?? {};
  const switches: Record<string, boolean> = {};
  for (const [k, v] of Object.entries(sw)) if (typeof v === "boolean") switches[k] = v;
  const kinds = (Array.isArray(o.kinds) ? o.kinds : []).flatMap((r) => {
    const k = obj(r);
    if (!k || typeof k.kind !== "string") return [];
    return [{
      kind: k.kind,
      handler: str(k.handler) ?? "",
      enabled: k.enabled !== false,
      max_running: num(k.max_running) ?? 0,
      max_attempts: num(k.max_attempts) ?? 0,
      timeout_seconds: num(k.timeout_seconds) ?? 0,
      running: num(k.running) ?? 0,
      queued: num(k.queued) ?? 0,
      due: num(k.due) ?? 0,
      done_24h: num(k.done_24h) ?? 0,
      failed_24h: num(k.failed_24h) ?? 0,
      avg_seconds_24h: num(k.avg_seconds_24h),
      last_done_at: str(k.last_done_at),
      last_failed_at: str(k.last_failed_at),
      last_error: str(k.last_error),
    }];
  });
  const alarms = (Array.isArray(o.alarms) ? o.alarms : []).flatMap((r) => {
    const a = obj(r);
    if (!a || typeof a.alarm_key !== "string" || typeof a.opened_at !== "string") return [];
    return [{ alarm_key: a.alarm_key, summary: str(a.summary), opened_at: a.opened_at, last_seen_at: str(a.last_seen_at) }];
  });
  return { checked_at: str(o.checked_at), switches, kinds, alarms };
}

export function parseJobsList(data: unknown): JobRow[] {
  if (!Array.isArray(data)) return [];
  return data.flatMap((r) => {
    const o = obj(r);
    const id = num(o?.id);
    if (!o || id === null || typeof o.kind !== "string" || typeof o.created_at !== "string") return [];
    if (!STATUSES.includes(o.status as JobStatus)) return [];
    return [{
      id,
      kind: o.kind,
      status: o.status as JobStatus,
      attempts: num(o.attempts) ?? 0,
      max_attempts: num(o.max_attempts) ?? 0,
      run_at: str(o.run_at) ?? o.created_at,
      created_at: o.created_at,
      started_at: str(o.started_at),
      finished_at: str(o.finished_at),
      last_error: str(o.last_error),
    }];
  });
}

/** Plain-word names for the job kinds the Owner knows. Unknown kinds show as written. */
export const JOB_KIND_LABEL: Record<string, string> = {
  "push.send": "Push notifications",
  "push.broadcast": "Admin broadcasts",
  "account.deletion_sweep": "Account deletion (180 days)",
  "cron.apply-scheduled-boosts": "Scheduled boosts",
  "cron.autoscale-ad-traffic": "Ad traffic",
  "cron.expire-gift-credits": "Gift-credit expiry",
  "cron.backup-reminder": "Backup reminder",
  "cron.send-reengagement-emails": "Re-engagement e-mails",
};
export const jobKindLabel = (kind: string) => JOB_KIND_LABEL[kind] ?? kind;

export function useAdminJobsOverview() {
  return useQuery({
    queryKey: queryKeys.adminJobsOverview(),
    queryFn: async () => {
      const { data, error } = await rpc("admin_jobs_overview");
      if (error) throw new Error(error.message ?? "Could not read the job engine");
      return parseJobsOverview(data);
    },
    refetchInterval: 60_000,
    staleTime: 30_000,
  });
}

export function useAdminJobsList(status: JobStatus | null, kind: string | null) {
  return useQuery({
    queryKey: queryKeys.adminJobsList(status ?? "all", kind ?? "all"),
    queryFn: async () => {
      const { data, error } = await rpc("admin_jobs_list", { _status: status, _kind: kind, _limit: 100 });
      if (error) throw new Error(error.message ?? "Could not read the job list");
      return parseJobsList(data);
    },
    refetchInterval: 60_000,
    staleTime: 30_000,
  });
}

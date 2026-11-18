/**
 * J5a harness sample — what admin_jobs_overview / admin_jobs_list answer,
 * shaped like production on 18 Nov 2026 (jobs status run 44221591998) plus one
 * staging-style failure so the failed state is visible in the picture.
 * Only answers when __harnessAdminJobs is set (scene screen-admin-jobs).
 */
export function adminJobsSampleOn(): boolean {
  return (globalThis as { __harnessAdminJobs?: boolean }).__harnessAdminJobs === true;
}

const t = (minAgo: number) => new Date(Date.UTC(2026, 10, 18, 2, 12) - minAgo * 60_000).toISOString();

const kind = (k: string, handler: string, o: Partial<Record<string, unknown>>) => ({
  kind: k, handler, enabled: true, max_running: 1, max_attempts: 1, timeout_seconds: 150,
  running: 0, queued: 0, due: 0, done_24h: 0, failed_24h: 0, avg_seconds_24h: null,
  last_done_at: null, last_failed_at: null, last_error: null, ...o,
});

export function sampleJobsOverview() {
  return {
    checked_at: t(0),
    switches: { job_engine: true, job_engine_push: true, job_engine_cron_http: true },
    kinds: [
      kind("account.deletion_sweep", "sql:public.account_deletion_sweep", { max_attempts: 3, timeout_seconds: 60, queued: 1, done_24h: 1, avg_seconds_24h: 90450.4, last_done_at: t(1440) }),
      kind("cron.apply-scheduled-boosts", "edge:apply-scheduled-boosts", { done_24h: 125, avg_seconds_24h: 60, last_done_at: t(2) }),
      kind("cron.autoscale-ad-traffic", "edge:autoscale-ad-traffic", { max_attempts: 2, done_24h: 2, avg_seconds_24h: 60, last_done_at: t(132) }),
      kind("cron.backup-reminder", "edge:backup-reminder", { max_attempts: 3 }),
      kind("cron.expire-gift-credits", "edge:expire-gift-credits", { max_attempts: 3, done_24h: 1, avg_seconds_24h: 59.8, last_done_at: t(118) }),
      kind("cron.send-reengagement-emails", "edge:send-reengagement-emails", {}),
      kind("push.broadcast", "edge:send-broadcast-push", { max_attempts: 3, timeout_seconds: 120, done_24h: 1, avg_seconds_24h: 64.6, last_done_at: t(546) }),
      kind("push.send", "edge:send-push", {
        max_running: 100, max_attempts: 4, timeout_seconds: 60, running: 3, queued: 2, due: 2,
        done_24h: 354, failed_24h: 1, avg_seconds_24h: 270.2, last_done_at: t(1), last_failed_at: t(300), last_error: "HTTP 401",
      }),
    ],
    alarms: [
      { alarm_key: "jobs:failed", summary: "1 job failed in the last 24 h (push.send)", opened_at: t(300), last_seen_at: t(1) },
    ],
  };
}

const KINDS = ["push.send", "push.send", "cron.apply-scheduled-boosts", "push.send", "cron.expire-gift-credits", "cron.autoscale-ad-traffic"];

export function sampleJobsList(b: Record<string, unknown>) {
  const rows = Array.from({ length: 24 }, (_, i) => {
    const k = KINDS[i % KINDS.length];
    const status = i === 0 ? "running" : i === 1 ? "queued" : i === 7 ? "failed" : "done";
    return {
      id: 9100 - i, kind: k, status, attempts: status === "queued" ? 0 : status === "failed" ? 4 : 1,
      max_attempts: k === "push.send" ? 4 : k === "cron.autoscale-ad-traffic" ? 2 : k === "cron.expire-gift-credits" ? 3 : 1,
      run_at: t(i * 5), created_at: t(i * 5), started_at: status === "queued" ? null : t(i * 5),
      finished_at: status === "done" || status === "failed" ? t(i * 5 - 1) : null,
      last_error: status === "failed" ? "HTTP 401" : null,
    };
  });
  return rows.filter((r) => (b._status ? r.status === b._status : true) && (b._kind ? r.kind === b._kind : true));
}

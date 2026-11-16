import { cdnHost, siteOrigin } from "./laneConfig.ts";

/**
 * This lane's own hosts, from its environment — the only hosts a push picture
 * may come from (see isSafeImageUrl in pushMessage.ts). Missing config → no
 * images, never a guess. Shared by send-push and send-broadcast-push.
 */
export function laneImageHosts(): string[] {
  const hosts: string[] = [];
  for (const read of [() => cdnHost(), () => new URL(siteOrigin()).hostname,
                      () => new URL(Deno.env.get("SUPABASE_URL") ?? "").hostname]) {
    try { const h = read(); if (h) hosts.push(h.toLowerCase()); } catch { /* not configured on this lane */ }
  }
  return hosts;
}

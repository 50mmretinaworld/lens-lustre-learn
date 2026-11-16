/**
 * PUSH CENTRE (PN3) — Admin → Push Notification. Owner approved items 1–10,
 * 16 Nov 2026. Write · Scheduled · History · Drafts · Templates.
 *
 * On a database without 20261116_1500 it shows the previous one-box page, so
 * the code can ship before the SQL is applied (same rule as the Users table).
 */
import { lazy, Suspense, useState } from "react";
import { Bell, Smartphone } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  EMPTY_DRAFT, PushRpcMissing, usePushAudience, usePushBroadcasts, type PushDraft, type PushView,
} from "@/hooks/admin/usePushCentre";
import PushComposer from "./PushComposer";
import { PushList } from "./PushLists";

const AdminPushBroadcast = lazy(() => import("@/components/admin/AdminPushBroadcast"));

type Tab = "write" | PushView;

/** Dev / harness only: `?pushui=old` shows the previous page for the Now-vs-New pictures. */
const showPrevious = () => import.meta.env.DEV && new URLSearchParams(window.location.search).get("pushui") === "old";

export default function AdminPushCentre() {
  const [tab, setTab] = useState<Tab>("write");
  const [draft, setDraft] = useState<PushDraft>(EMPTY_DRAFT);
  const everyone = usePushAudience({ kind: "all" });
  const scheduled = usePushBroadcasts("scheduled");

  if (showPrevious() || everyone.error instanceof PushRpcMissing || scheduled.error instanceof PushRpcMissing) {
    return <Suspense fallback={null}><AdminPushBroadcast /></Suspense>;
  }

  const c = everyone.data;
  const tabs: Array<{ key: Tab; label: string; n?: number }> = [
    { key: "write", label: draft.id ? "Edit message" : "New message" },
    { key: "scheduled", label: "Scheduled", n: scheduled.data?.total },
    { key: "history", label: "History" },
    { key: "drafts", label: "Drafts" },
    { key: "templates", label: "Templates" },
  ];
  const open = (d: PushDraft) => { setDraft(d); setTab("write"); };

  return (
    <div className="space-y-4" data-testid="push-centre">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="flex items-center gap-2 text-lg font-semibold" style={{ fontFamily: "var(--font-heading)" }}>
            <Bell className="h-5 w-5 text-primary" /> Push notifications
          </h2>
          <p className="text-xs text-muted-foreground">Messages to members' phones through the 50mm Retina app. The website cannot receive them.</p>
        </div>
        {c && (
          <div className="flex flex-wrap gap-2 text-[11px]" data-testid="push-reach-summary">
            <span className="inline-flex items-center gap-1.5 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-3 py-1 text-emerald-700 dark:text-emerald-400">
              <Smartphone className="h-3.5 w-3.5" /> {c.reachable_members} of {c.matched} members can receive · {c.devices} phones
            </span>
            <span className={cn("inline-flex items-center rounded-full border px-3 py-1", c.scheduling_on ? "border-border text-muted-foreground" : "border-amber-500/30 bg-amber-500/10 text-amber-700")}>
              Scheduling {c.scheduling_on ? "on" : "off"}
            </span>
          </div>
        )}
      </div>

      <div className="flex gap-1 overflow-x-auto border-b border-border" role="tablist">
        {tabs.map((t) => (
          <button key={t.key} type="button" role="tab" aria-selected={tab === t.key} data-testid={`push-tab-${t.key}`}
            onClick={() => setTab(t.key)}
            className={cn("-mb-px whitespace-nowrap border-b-2 px-3 py-2 text-xs transition-colors",
              tab === t.key ? "border-primary font-semibold text-foreground" : "border-transparent text-muted-foreground hover:text-foreground")}>
            {t.label}{typeof t.n === "number" && t.n > 0 && <span className="ml-1.5 rounded-full bg-primary/10 px-1.5 text-[10px] text-primary">{t.n}</span>}
          </button>
        ))}
        {tab === "write" && draft !== EMPTY_DRAFT && (
          <button type="button" onClick={() => setDraft(EMPTY_DRAFT)} className="ml-auto whitespace-nowrap px-2 text-[11px] text-muted-foreground hover:text-foreground">Start over</button>
        )}
      </div>

      {tab === "write"
        ? <PushComposer draft={draft} setDraft={setDraft} onDone={(where) => { if (where !== "drafts" && where !== "templates") setDraft(EMPTY_DRAFT); setTab(where); }} />
        : <PushList view={tab} onEdit={open} />}
    </div>
  );
}

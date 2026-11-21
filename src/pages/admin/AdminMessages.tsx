/**
 * M8b · ADMIN → Users & Community → Messages. Routed at /admin/messages (via AdminPanel).
 * One page for the private-messages controls the Owner approved (15–18 Nov 2026):
 *   Who can message · Word guard · Reports · Message boxes · Broadcast · History.
 * The database does the checking (admin only, reason on every change, log rows);
 * this page only shows the state and collects the reasons.
 */
import { useState } from "react";
import { Loader2, RefreshCw } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useAuth } from "@/hooks/core/useAuth";
import SwitchPanel, { MODE_TEXT } from "@/components/admin/messages/SwitchPanel";
import { WordsPanel } from "@/components/admin/messages/SafetyPanel";
import ReportsPanel from "@/components/admin/messages/ReportsPanel";
import MembersPanel from "@/components/admin/messages/MembersPanel";
import BroadcastPanel from "@/components/admin/messages/BroadcastPanel";
import HistoryPanel from "@/components/admin/messages/HistoryPanel";
import { useMessageAdminState, useMessageReports } from "@/hooks/admin/useAdminMessages";

const TABS = ["who", "words", "reports", "boxes", "broadcast", "history"];

const AdminMessages = () => {
  const state = useMessageAdminState();
  const reports = useMessageReports("open");
  const { user } = useAuth();
  const [tab, setTab] = useState(() => {
    // /admin/messages?tab=words opens that tab (also used by the screenshot harness)
    const t = typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("tab");
    return t && TABS.includes(t) ? t : "who";
  });
  const s = state.data;
  const openReports = reports.data?.length ?? 0;
  // names of people shown in the history come with the state (list + rules); anyone else shows a short id
  const names = new Map<string, string>();
  for (const m of s?.members ?? []) if (m.full_name) names.set(m.user_id, m.full_name);
  for (const r of s?.rules ?? []) if (r.full_name) names.set(r.user_id, r.full_name);

  return (
    <div className="space-y-4 px-4 py-4 sm:px-0" data-testid="admin-messages">
      <header className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-lg font-semibold" style={{ fontFamily: "var(--font-heading)" }}>Messages</h2>
          <p className="mt-1 text-[11px] text-muted-foreground">
            Private messages between members. Every change here asks for a reason and is kept in the history for a year.
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={() => { void state.refetch(); void reports.refetch(); }}>
          <RefreshCw className="mr-1 h-4 w-4" aria-hidden="true" />Refresh
        </Button>
      </header>

      {state.isLoading && <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin text-muted-foreground" aria-label="Loading" /></div>}
      {state.error && <p className="rounded-lg border border-destructive p-3 text-sm text-destructive">Could not read the messages switch: {(state.error as Error).message}</p>}

      {s && (
        <>
          <div className="flex flex-wrap gap-2" aria-label="Status" data-testid="messages-status">
            <Badge variant={s.mode === "blocked_all" ? "destructive" : "secondary"}>Now: {MODE_TEXT[s.mode].title}</Badge>
            <Badge variant="outline">Groups: {s.groups_enabled ? "On" : "Off"}</Badge>
            <Badge variant="outline">List: {s.members.length}</Badge>
            {openReports > 0 && <Badge variant="destructive">{openReports} open report{openReports === 1 ? "" : "s"}</Badge>}
          </div>
          <Tabs value={tab} onValueChange={setTab}>
            <TabsList className="h-auto flex-wrap justify-start">
              <TabsTrigger value="who">Who can message</TabsTrigger>
              <TabsTrigger value="words">Word guard</TabsTrigger>
              <TabsTrigger value="reports">Reports{openReports > 0 ? ` (${openReports})` : ""}</TabsTrigger>
              <TabsTrigger value="boxes">Message boxes</TabsTrigger>
              <TabsTrigger value="broadcast">Broadcast</TabsTrigger>
              <TabsTrigger value="history">History</TabsTrigger>
            </TabsList>
            <TabsContent value="who" className="pt-3"><SwitchPanel state={s} /></TabsContent>
            <TabsContent value="words" className="pt-3"><WordsPanel /></TabsContent>
            <TabsContent value="reports" className="pt-3"><ReportsPanel /></TabsContent>
            <TabsContent value="boxes" className="pt-3"><MembersPanel /></TabsContent>
            <TabsContent value="broadcast" className="pt-3"><BroadcastPanel /></TabsContent>
            <TabsContent value="history" className="pt-3"><HistoryPanel log={s.log} me={user?.id ?? null} names={names} /></TabsContent>
          </Tabs>
        </>
      )}
    </div>
  );
};

export default AdminMessages;

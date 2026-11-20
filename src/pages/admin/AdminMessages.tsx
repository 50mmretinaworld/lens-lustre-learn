/**
 * M8b · ADMIN → Users & Community → Messages. Routed at /admin/messages (via AdminPanel).
 * One page for the private-messages controls the Owner approved (15–18 Nov 2026):
 *   Who can message · Word guard · Held · Chats (logged viewer) · History.
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
import { WordsPanel, HeldPanel } from "@/components/admin/messages/SafetyPanel";
import ChatsPanel from "@/components/admin/messages/ChatsPanel";
import { useMessageAdminState, useMessageHeldQueue, type ControlLogRow } from "@/hooks/admin/useAdminMessages";

const TABS = ["who", "words", "held", "chats", "history"];
const AREA_TEXT: Record<string, string> = {
  mode: "Who can message", groups: "Groups", list: "Member list", member_rule: "Member rules",
  word_rule: "Word list", review: "Held message", lookup: "Chat list looked up",
};
const when = (iso: string) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};

function History({ log, me, names }: { log: ControlLogRow[]; me: string | null; names: Map<string, string> }) {
  if (log.length === 0) return <p className="text-sm text-muted-foreground">No changes yet.</p>;
  return (
    <ul className="divide-y divide-border rounded-lg border border-border" data-testid="messages-history">
      {log.map((l, i) => (
        <li key={`${l.at}-${i}`} className="space-y-0.5 p-2 text-sm" data-testid="messages-history-row">
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant="secondary">{AREA_TEXT[l.area] ?? l.area}</Badge>
            <span className="font-medium">{l.actor === me ? "You" : l.actor ? (names.get(l.actor) ?? l.actor.slice(0, 8)) : "System"}</span>
            {l.user_id && <span className="text-xs text-muted-foreground">about {names.get(l.user_id) ?? l.user_id.slice(0, 8)}</span>}
            <span className="ml-auto text-xs text-muted-foreground">{when(l.at)}</span>
          </div>
          {(l.old || l.new) && <div className="text-xs text-muted-foreground">{l.old ?? "—"} → {l.new ?? "—"}</div>}
          <div className="text-xs">“{l.reason}”</div>
        </li>
      ))}
    </ul>
  );
}

const AdminMessages = () => {
  const state = useMessageAdminState();
  const held = useMessageHeldQueue();
  const { user } = useAuth();
  const [tab, setTab] = useState(() => {
    // /admin/messages?tab=words opens that tab (also used by the screenshot harness)
    const t = typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("tab");
    return t && TABS.includes(t) ? t : "who";
  });
  const s = state.data;
  const heldCount = held.data?.length ?? 0;
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
        <Button variant="outline" size="sm" onClick={() => { void state.refetch(); void held.refetch(); }}>
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
            {heldCount > 0 && <Badge variant="destructive">{heldCount} held</Badge>}
          </div>
          <Tabs value={tab} onValueChange={setTab}>
            <TabsList className="h-auto flex-wrap justify-start">
              <TabsTrigger value="who">Who can message</TabsTrigger>
              <TabsTrigger value="words">Word guard</TabsTrigger>
              <TabsTrigger value="held">Held{heldCount > 0 ? ` (${heldCount})` : ""}</TabsTrigger>
              <TabsTrigger value="chats">Chats</TabsTrigger>
              <TabsTrigger value="history">History</TabsTrigger>
            </TabsList>
            <TabsContent value="who" className="pt-3"><SwitchPanel state={s} /></TabsContent>
            <TabsContent value="words" className="pt-3"><WordsPanel /></TabsContent>
            <TabsContent value="held" className="pt-3"><HeldPanel /></TabsContent>
            <TabsContent value="chats" className="pt-3"><ChatsPanel /></TabsContent>
            <TabsContent value="history" className="pt-3"><History log={s.log} me={user?.id ?? null} names={names} /></TabsContent>
          </Tabs>
        </>
      )}
    </div>
  );
};

export default AdminMessages;

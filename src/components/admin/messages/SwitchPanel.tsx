/**
 * M8b · Admin → Messages → "Who can message": the 4-mode switch, the list, the
 * groups switch and per-member rules. All changes go through ReasonDialog (the
 * database refuses a change without a reason and logs it).
 */
import { useState } from "react";
import { Download, Loader2, Trash2, SlidersHorizontal } from "lucide-react";
import AdminDataTable, { type DTColumn } from "@/components/admin/AdminDataTable";
import AdminSidePanel, { PanelField } from "@/components/admin/AdminSidePanel";
import { cmpDate, cmpText, downloadCsv, useClientTable } from "@/components/admin/useClientTable";
import { MemberAvatar } from "@/components/admin/users/memberUi";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { toast } from "@/hooks/core/use-toast";
import ProfileTypeaheadPicker from "@/components/admin/ProfileTypeaheadPicker";
import ReasonDialog, { type ReasonRequest } from "./ReasonDialog";
import {
  MODES, adminMessageCall, useRefreshAdminMessages,
  type MessageAdminState, type MessageMode, type MemberRule, type ListedMember,
} from "@/hooks/admin/useAdminMessages";

export const MODE_TEXT: Record<MessageMode, { title: string; blurb: string }> = {
  allowed_selected: { title: "Only people on my list", blurb: "Messaging works for the members on the list below. Everyone else sees nothing." },
  allowed_all: { title: "Everyone", blurb: "Every member can message, within the rules and limits." },
  blocked_selected: { title: "Everyone except my list", blurb: "Messaging works for all members, but not for those on the list below." },
  blocked_all: { title: "Nobody (paused)", blurb: "Messaging is off for all members. Existing chats stay safe." },
};

const listTitle = (mode: MessageMode) =>
  mode === "allowed_selected" ? "Allowed members" : mode === "blocked_selected" ? "Excluded members" : "Member list (not used in this mode)";

const nameOf = (m: { full_name: string | null; username?: string | null; user_id: string }) =>
  m.full_name || (m.username ? `@${m.username}` : m.user_id.slice(0, 8));

/** The rules of one member: text / photos / groups / friends-only / daily limit / pause until. */
function RuleEditor({ target, current, onClose, onSaved }: {
  target: { user_id: string; name: string } | null; current: MemberRule | null; onClose: () => void; onSaved: () => void;
}) {
  const [text, setText] = useState(true);
  const [photos, setPhotos] = useState(true);
  const [groups, setGroups] = useState(true);
  const [friends, setFriends] = useState(false);
  const [limit, setLimit] = useState("");
  const [until, setUntil] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [seen, setSeen] = useState<string | null>(null);

  // load the member's current rule when the dialog opens for a new member
  if (target && seen !== target.user_id) {
    setSeen(target.user_id);
    setText(current?.text_ok ?? true); setPhotos(current?.photos_ok ?? true); setGroups(current?.groups_ok ?? true);
    setFriends(current?.friends_only ?? false); setLimit(current?.daily_limit != null ? String(current.daily_limit) : "");
    setUntil(current?.blocked_until ? current.blocked_until.slice(0, 10) : ""); setReason("");
  }
  if (!target && seen !== null) setSeen(null);

  const save = async () => {
    if (!target || !reason.trim() || busy) return;
    const n = limit.trim() === "" ? null : Number(limit);
    if (n !== null && (!Number.isInteger(n) || n < 0 || n > 100000)) {
      toast({ title: "Daily limit", description: "Use a whole number from 0 to 100000, or leave it empty.", variant: "destructive" });
      return;
    }
    setBusy(true);
    try {
      await adminMessageCall("message_admin_set_member_rule", {
        _user: target.user_id, _text_ok: text, _photos_ok: photos, _groups_ok: groups, _friends_only: friends,
        _daily_limit: n, _blocked_until: until ? new Date(`${until}T23:59:59`).toISOString() : null, _reason: reason.trim(),
      });
      toast({ title: "Done", description: `Rules saved for ${target.name}` });
      onSaved();
      onClose();
    } catch (e) {
      toast({ title: "Not done", description: e instanceof Error ? e.message : "request failed", variant: "destructive" });
    } finally { setBusy(false); }
  };

  const row = (label: string, on: boolean, set: (v: boolean) => void, id: string) => (
    <label className="flex items-center justify-between gap-3 py-1.5 text-sm" htmlFor={id}>
      <span>{label}</span><Switch id={id} checked={on} onCheckedChange={set} />
    </label>
  );

  return (
    <Dialog open={!!target} onOpenChange={(o) => { if (!o && !busy) onClose(); }}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Rules for {target?.name}</DialogTitle>
          <DialogDescription>These apply on top of the main switch. Leave everything on to give the member normal messaging.</DialogDescription>
        </DialogHeader>
        <div className="divide-y divide-border">
          {row("Can send text", text, setText, "rule-text")}
          {row("Can send photos", photos, setPhotos, "rule-photos")}
          {row("Can use groups", groups, setGroups, "rule-groups")}
          {row("Can message friends only", friends, setFriends, "rule-friends")}
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="space-y-1 text-sm"><span className="font-medium">Messages per day</span>
            <Input inputMode="numeric" value={limit} onChange={(e) => setLimit(e.target.value)} placeholder="Normal limit" /></label>
          <label className="space-y-1 text-sm"><span className="font-medium">Paused until</span>
            <Input type="date" value={until} onChange={(e) => setUntil(e.target.value)} /></label>
        </div>
        <label className="space-y-1 text-sm"><span className="font-medium">Reason (required)</span>
          <Textarea value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} rows={2} data-testid="messages-rule-reason" /></label>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button onClick={() => void save()} disabled={busy || !reason.trim()}>
            {busy && <Loader2 className="mr-1 h-4 w-4 animate-spin" aria-hidden="true" />}Save rules
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

const dayText = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
};
const isPaused = (r: MemberRule) => !!r.blocked_until && new Date(r.blocked_until) > new Date();
function RuleBadges({ r }: { r: MemberRule }) {
  return (
    <div className="flex flex-wrap gap-1">
      {!r.text_ok && <Badge variant="destructive">No text</Badge>}
      {!r.photos_ok && <Badge variant="destructive">No photos</Badge>}
      {!r.groups_ok && <Badge variant="destructive">No groups</Badge>}
      {r.friends_only && <Badge variant="outline">Friends only</Badge>}
      {r.daily_limit != null && <Badge variant="outline">{r.daily_limit} / day</Badge>}
      {isPaused(r) && <Badge variant="destructive">Paused to {r.blocked_until?.slice(0, 10)}</Badge>}
    </div>
  );
}

/** The member list as a table: search, tabs, tick-boxes → remove together, a side panel per member. */
function ListTable({ state, onRules, onRemove }: { state: MessageAdminState; onRules: (m: ListedMember) => void; onRemove: (ms: ListedMember[]) => void }) {
  const [tab, setTab] = useState<"all" | "rules">("all");
  const [open, setOpen] = useState<ListedMember | null>(null);
  const ruleOf = (id: string) => state.rules.find((r) => r.user_id === id) ?? null;
  const rows = state.members;
  const t = useClientTable<ListedMember>(rows, {
    rowKey: (m) => m.user_id,
    searchText: (m) => `${nameOf(m)} ${m.username ?? ""} ${m.note ?? ""}`,
    sorts: { member: (a, b) => cmpText(nameOf(a), nameOf(b)), added: (a, b) => cmpDate(a.listed_at, b.listed_at) },
    defaultSort: { key: "added", dir: "desc" },
    keep: (m) => tab === "all" || !!state.rules.find((r) => r.user_id === m.user_id),
  });
  const columns: DTColumn<ListedMember>[] = [
    { key: "member", header: "Member", sortKey: "member", cell: (m) => (
      <div className="flex items-center gap-3"><MemberAvatar m={{ avatar_url: m.avatar_url, full_name: m.full_name, email: null }} size={32} />
        <div className="min-w-0"><p className="truncate font-medium">{nameOf(m)}</p>{m.username && <p className="truncate text-xs text-muted-foreground">@{m.username}</p>}</div></div>) },
    { key: "rules", header: "Rules", cell: (m) => { const r = ruleOf(m.user_id); return r ? <RuleBadges r={r} /> : <span className="text-sm text-muted-foreground">Normal</span>; } },
    { key: "added", header: "Added", sortKey: "added", className: "whitespace-nowrap", cell: (m) => <span className="text-sm text-muted-foreground">{dayText(m.listed_at)}</span> },
    { key: "act", header: "", className: "w-28 text-right", cell: (m) => (
      <Button size="sm" variant="outline" onClick={(e) => { e.stopPropagation(); onRules(m); }}><SlidersHorizontal className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Rules</Button>) },
  ];
  return (
    <>
      <AdminDataTable<ListedMember>
        testId="messages-list-table" rows={t.view} rowKey={(m) => m.user_id} columns={columns}
        tabs={[{ key: "all", label: "On the list", count: rows.length }, { key: "rules", label: "With rules", count: rows.filter((m) => ruleOf(m.user_id)).length }]}
        tab={tab} onTab={(k) => { setTab(k as "all" | "rules"); t.setPage(0); }}
        search={t.search} onSearch={t.setSearch} searchPlaceholder="Search the list"
        toolbar={<Button variant="outline" size="sm" className="h-9" disabled={t.total === 0}
          onClick={() => downloadCsv("message-list.csv", ["Member", "Username", "Added", "Note"], t.filtered.map((m) => [nameOf(m), m.username, m.listed_at, m.note]))}><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export</Button>}
        sort={t.sort} onSort={t.onSort} selected={t.selected} onSelectedChange={t.setSelected}
        bulkBar={() => <Button size="sm" variant="outline" onClick={() => onRemove(t.pickedRows)}><Trash2 className="mr-1 h-4 w-4" aria-hidden="true" />Remove from the list</Button>}
        page={t.page} pageSize={t.pageSize} total={t.total} onPage={t.setPage} onPageSize={t.setPageSize}
        emptyText={t.search ? `No one matches “${t.search}”.` : state.mode === "allowed_selected" ? "No one is on the list, so nobody can message yet." : "No one is on the list."}
        onRowClick={setOpen}
        phoneCard={(m) => <div className="flex items-center gap-2"><p className="min-w-0 flex-1 truncate font-medium">{nameOf(m)}</p>{ruleOf(m.user_id) && <Badge variant="outline">Has rules</Badge>}</div>}
      />
      <AdminSidePanel open={!!open} onClose={() => setOpen(null)} testId="list-side-panel" title={open ? nameOf(open) : ""} subtitle={open?.username ? `@${open.username}` : "On the list"}
        footer={open && (<>
          <Button variant="outline" onClick={() => { onRules(open); setOpen(null); }}><SlidersHorizontal className="mr-1 h-4 w-4" aria-hidden="true" />Rules</Button>
          <Button variant="outline" onClick={() => { onRemove([open]); setOpen(null); }}><Trash2 className="mr-1 h-4 w-4" aria-hidden="true" />Remove from the list</Button>
        </>)}>
        {open && (<>
          <PanelField label="On the list since">{dayText(open.listed_at)}</PanelField>
          {open.note && <PanelField label="Note">{open.note}</PanelField>}
          <PanelField label="Rules">{ruleOf(open.user_id) ? <RuleBadges r={ruleOf(open.user_id) as MemberRule} /> : "Normal messaging"}</PanelField>
        </>)}
      </AdminSidePanel>
    </>
  );
}

/** Members with special rules as a table: edit in the dialog, clear together, details in a side panel. */
function RulesTable({ state, onEdit, onClear }: { state: MessageAdminState; onEdit: (r: MemberRule) => void; onClear: (rs: MemberRule[]) => void }) {
  const [tab, setTab] = useState<"all" | "paused">("all");
  const [open, setOpen] = useState<MemberRule | null>(null);
  const rows = state.rules;
  const t = useClientTable<MemberRule>(rows, {
    rowKey: (r) => r.user_id,
    searchText: (r) => `${nameOf(r)} ${r.reason ?? ""}`,
    sorts: { member: (a, b) => cmpText(nameOf(a), nameOf(b)), set: (a, b) => cmpDate(a.set_at, b.set_at) },
    defaultSort: { key: "set", dir: "desc" },
    keep: (r) => tab === "all" || isPaused(r),
  });
  const columns: DTColumn<MemberRule>[] = [
    { key: "member", header: "Member", sortKey: "member", cell: (r) => <span className="font-medium">{nameOf(r)}</span> },
    { key: "rules", header: "Rules", cell: (r) => <RuleBadges r={r} /> },
    { key: "reason", header: "Reason", className: "max-w-[260px]", cell: (r) => <span className="line-clamp-2 text-sm text-muted-foreground">{r.reason ? `“${r.reason}”` : "—"}</span> },
    { key: "set", header: "Set", sortKey: "set", className: "whitespace-nowrap", cell: (r) => <span className="text-sm text-muted-foreground">{dayText(r.set_at)}</span> },
    { key: "act", header: "", className: "w-36 text-right", cell: (r) => (
      <span className="flex justify-end gap-1" onClick={(e) => e.stopPropagation()}>
        <Button size="sm" variant="outline" onClick={() => onEdit(r)}>Edit</Button>
        <Button size="sm" variant="outline" onClick={() => onClear([r])}>Clear</Button>
      </span>) },
  ];
  return (
    <>
      <AdminDataTable<MemberRule>
        testId="messages-rules-table" rows={t.view} rowKey={(r) => r.user_id} columns={columns}
        tabs={[{ key: "all", label: "All with rules", count: rows.length }, { key: "paused", label: "Paused now", count: rows.filter(isPaused).length, warn: true }]}
        tab={tab} onTab={(k) => { setTab(k as "all" | "paused"); t.setPage(0); }}
        search={t.search} onSearch={t.setSearch} searchPlaceholder="Search member or reason"
        toolbar={<Button variant="outline" size="sm" className="h-9" disabled={t.total === 0}
          onClick={() => downloadCsv("message-member-rules.csv", ["Member", "Text", "Photos", "Groups", "Friends only", "Per day", "Paused until", "Reason", "Set"],
            t.filtered.map((r) => [nameOf(r), r.text_ok, r.photos_ok, r.groups_ok, r.friends_only, r.daily_limit, r.blocked_until, r.reason, r.set_at]))}><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export</Button>}
        sort={t.sort} onSort={t.onSort} selected={t.selected} onSelectedChange={t.setSelected}
        bulkBar={() => <Button size="sm" variant="outline" onClick={() => onClear(t.pickedRows)}>Clear rules</Button>}
        page={t.page} pageSize={t.pageSize} total={t.total} onPage={t.setPage} onPageSize={t.setPageSize}
        emptyText={t.search ? `No one matches “${t.search}”.` : "No member has special rules."}
        onRowClick={setOpen}
        phoneCard={(r) => <div className="space-y-1"><p className="font-medium">{nameOf(r)}</p><RuleBadges r={r} /></div>}
      />
      <AdminSidePanel open={!!open} onClose={() => setOpen(null)} testId="rule-side-panel" title={open ? nameOf(open) : ""} subtitle="Special rules"
        footer={open && (<>
          <Button onClick={() => { onEdit(open); setOpen(null); }}>Edit rules</Button>
          <Button variant="outline" onClick={() => { onClear([open]); setOpen(null); }}>Clear rules</Button>
        </>)}>
        {open && (<>
          <PanelField label="Rules"><RuleBadges r={open} /></PanelField>
          <PanelField label="Reason">{open.reason ? `“${open.reason}”` : "—"}</PanelField>
          <PanelField label="Set">{dayText(open.set_at)}</PanelField>
        </>)}
      </AdminSidePanel>
    </>
  );
}

export default function SwitchPanel({ state }: { state: MessageAdminState }) {
  const refresh = useRefreshAdminMessages();
  const [request, setRequest] = useState<ReasonRequest | null>(null);
  const [ruleFor, setRuleFor] = useState<{ user_id: string; name: string } | null>(null);
  const [pk, setPk] = useState(0); // remounts the pickers after a pick so they are empty again
  const ruleOf = (id: string) => state.rules.find((r) => r.user_id === id) ?? null;
  const listed = new Set(state.members.map((m) => m.user_id));

  const askMode = (mode: MessageMode) => {
    if (mode === state.mode) return;
    setRequest({
      title: `Change to “${MODE_TEXT[mode].title}”?`,
      body: MODE_TEXT[mode].blurb,
      button: "Change",
      destructive: mode === "allowed_all",
      doneText: `Messaging: ${MODE_TEXT[mode].title}`,
      run: async (reason) => { await adminMessageCall("message_admin_set_mode", { _mode: mode, _reason: reason }); await refresh(); },
    });
  };
  const askGroups = (on: boolean) => setRequest({
    title: on ? "Turn groups on?" : "Turn groups off?",
    body: on ? "Members who may message can make groups of friends (up to 20 people)." : "Group chats stop working. Existing groups stay safe.",
    button: on ? "Turn on" : "Turn off",
    doneText: on ? "Groups are on" : "Groups are off",
    run: async (reason) => { await adminMessageCall("message_admin_set_groups", { _on: on, _reason: reason }); await refresh(); },
  });
  const askAdd = (p: { id: string; full_name: string | null }) => {
    const name = p.full_name || p.id.slice(0, 8);
    if (listed.has(p.id)) { toast({ title: "Already on the list", description: name }); return; }
    setRequest({
      title: `Add ${name} to the list?`, body: "Whether this lets them message depends on the mode above.", button: "Add",
      doneText: `${name} added`,
      run: async (reason) => { await adminMessageCall("message_admin_list_add", { _user: p.id, _reason: reason }); await refresh(); },
    });
  };
  const askRemoveMany = (ms: ListedMember[]) => {
    if (ms.length === 0) return;
    const name = ms.length === 1 ? nameOf(ms[0]) : `${ms.length} members`;
    setRequest({
      title: `Remove ${name} from the list?`, body: "Their existing chats are not touched.", button: "Remove", destructive: true,
      doneText: `${name} removed`,
      run: async (reason) => { for (const m of ms) await adminMessageCall("message_admin_list_remove", { _user: m.user_id, _reason: reason }); await refresh(); },
    });
  };
  const askClearMany = (rs: MemberRule[]) => {
    if (rs.length === 0) return;
    const name = rs.length === 1 ? nameOf(rs[0]) : `${rs.length} members`;
    setRequest({
      title: `Clear the rules for ${name}?`, body: "They go back to normal messaging.", button: "Clear rules",
      doneText: `Rules cleared for ${name}`,
      run: async (reason) => { for (const r of rs) await adminMessageCall("message_admin_clear_member_rule", { _user: r.user_id, _reason: reason }); await refresh(); },
    });
  };

  return (
    <div className="space-y-6">
      <section aria-label="Who can message" className="space-y-2" data-testid="messages-modes">
        <h3 className="text-sm font-semibold">Who can message right now</h3>
        <div role="radiogroup" aria-label="Messaging mode" className="grid gap-2 sm:grid-cols-2">
          {MODES.map((m) => (
            <button key={m} type="button" role="radio" aria-checked={state.mode === m} onClick={() => askMode(m)}
              className={`rounded-lg border p-3 text-left transition-colors ${state.mode === m ? "border-primary bg-primary/5" : "border-border hover:bg-muted/40"}`}>
              <span className="flex items-center justify-between gap-2 font-medium">{MODE_TEXT[m].title}{state.mode === m && <Badge>Now</Badge>}</span>
              <span className="mt-1 block text-xs text-muted-foreground">{MODE_TEXT[m].blurb}</span>
            </button>
          ))}
        </div>
        <label className="flex items-center justify-between gap-3 rounded-lg border border-border p-3 text-sm" htmlFor="groups-switch">
          <span><b>Groups</b><span className="block text-xs text-muted-foreground">Friends-only groups, up to 20 people. Off until you turn it on.</span></span>
          <Switch id="groups-switch" checked={state.groups_enabled} onCheckedChange={askGroups} />
        </label>
      </section>

      <section aria-label="Member list" className="space-y-2" data-testid="messages-list">
        <h3 className="text-sm font-semibold">{listTitle(state.mode)} <span className="font-normal text-muted-foreground">({state.members.length})</span></h3>
        <ProfileTypeaheadPicker key={`add-${pk}`} label="Add a member" hint="Search by name or e-mail. You give the reason on the next step." value={null}
          onChange={(p) => { if (p) { askAdd({ id: p.id, full_name: p.full_name }); setPk((n) => n + 1); } }} />
        <ListTable
          state={state}
          onRules={(m) => setRuleFor({ user_id: m.user_id, name: nameOf(m) })}
          onRemove={(ms) => askRemoveMany(ms)}
        />
      </section>

      <section aria-label="Member rules" className="space-y-2" data-testid="messages-rules">
        <h3 className="text-sm font-semibold">Members with special rules <span className="font-normal text-muted-foreground">({state.rules.length})</span></h3>
        <ProfileTypeaheadPicker key={`rule-${pk}`} label="Set rules for a member" hint="Any member, listed or not: pause, text / photos / groups off, friends only, daily limit." value={null}
          onChange={(p) => { if (p) { setRuleFor({ user_id: p.id, name: p.full_name || p.id.slice(0, 8) }); setPk((n) => n + 1); } }} />
        <RulesTable
          state={state}
          onEdit={(r) => setRuleFor({ user_id: r.user_id, name: nameOf(r) })}
          onClear={(rs) => askClearMany(rs)}
        />
      </section>

      <ReasonDialog request={request} onClose={() => setRequest(null)} />
      <RuleEditor target={ruleFor} current={ruleFor ? ruleOf(ruleFor.user_id) : null} onClose={() => setRuleFor(null)} onSaved={() => void refresh()} />
    </div>
  );
}

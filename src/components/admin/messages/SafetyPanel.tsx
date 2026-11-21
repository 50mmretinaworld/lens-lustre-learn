/**
 * M8b/D · Admin → Messages → "Word guard" (the word list) on the ONE shared admin table.
 * The guard works by itself: Block or Help, no approval queue. English starter list only; more languages
 * come from the Owner / lawyer. Every change to the list asks for a reason (one reason covers a bulk change).
 *   table: search · tabs (All / Block / Help / On / Off) · kind filter · sort · tick-boxes → bulk on / off ·
 *          click a row → side panel (what it does, on/off) · "Add a word" side panel · export.
 */
import { useMemo, useState } from "react";
import { Download, Plus, Power, PowerOff } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import AdminDataTable, { type DTColumn } from "@/components/admin/AdminDataTable";
import AdminSidePanel, { PanelField } from "@/components/admin/AdminSidePanel";
import { cmpDate, cmpText, downloadCsv, useClientTable } from "@/components/admin/useClientTable";
import ReasonDialog, { type ReasonRequest } from "./ReasonDialog";
import {
  adminMessageCall, useMessageWordRules, useRefreshAdminMessages, type WordRule,
} from "@/hooks/admin/useAdminMessages";

const ACTION_TEXT: Record<WordRule["action"], { label: string; blurb: string; variant: "destructive" | "secondary" }> = {
  block: { label: "Block", blurb: "The message is not sent. The sender is told to change the words; the receiver never sees it.", variant: "destructive" },
  help: { label: "Help", blurb: "Sent; the sender sees the helpline and you get an alarm.", variant: "secondary" },
};
const CATEGORY_TEXT: Record<string, string> = {
  abuse: "Abuse", threat: "Threats", political: "Political", self_harm: "Self-harm", abnormal: "Abnormal",
};
const selectClass = "h-9 rounded-md border border-border bg-background px-2 text-sm outline-none focus:border-primary";
type Tab = "all" | "block" | "help" | "on" | "off";
const added = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
};

export function WordsPanel() {
  const words = useMessageWordRules();
  const refresh = useRefreshAdminMessages();
  const [request, setRequest] = useState<ReasonRequest | null>(null);
  const [tab, setTab] = useState<Tab>("all");
  const [kind, setKind] = useState("all");
  const [open, setOpen] = useState<WordRule | null>(null);
  const [adding, setAdding] = useState(false);
  const [category, setCategory] = useState("abuse");
  const [action, setAction] = useState<WordRule["action"]>("block");
  const [pattern, setPattern] = useState("");
  const [lang, setLang] = useState("en");

  const rules = useMemo(() => words.data ?? [], [words.data]);
  const counts = useMemo(() => ({
    all: rules.length, block: rules.filter((r) => r.action === "block").length, help: rules.filter((r) => r.action === "help").length,
    on: rules.filter((r) => r.active).length, off: rules.filter((r) => !r.active).length,
  }), [rules]);

  const t = useClientTable<WordRule>(rules, {
    rowKey: (r) => String(r.id),
    searchText: (r) => `${r.pattern} ${CATEGORY_TEXT[r.category] ?? r.category} ${r.lang ?? ""}`,
    sorts: {
      word: (a, b) => cmpText(a.pattern, b.pattern), kind: (a, b) => cmpText(CATEGORY_TEXT[a.category] ?? a.category, CATEGORY_TEXT[b.category] ?? b.category),
      action: (a, b) => cmpText(a.action, b.action), status: (a, b) => Number(a.active) - Number(b.active), added: (a, b) => cmpDate(a.added_at, b.added_at),
    },
    defaultSort: { key: "kind", dir: "asc" },
    keep: (r) => (tab === "all" || (tab === "block" || tab === "help" ? r.action === tab : tab === "on" ? r.active : !r.active)) && (kind === "all" || r.category === kind),
  });

  const askAdd = () => {
    const p = pattern.trim();
    if (p.length < 2) return;
    setRequest({
      title: "Add this word or phrase?",
      body: `“${p}” → ${ACTION_TEXT[action].label}: ${ACTION_TEXT[action].blurb} Whole words only, any capital letters.`,
      button: "Add", doneText: `“${p}” added`,
      run: async (reason) => {
        await adminMessageCall("message_admin_word_add", { _category: category, _pattern: p, _lang: lang.trim() || null, _action: action, _reason: reason });
        setPattern("");
        setAdding(false);
        await refresh();
      },
    });
  };
  const askActive = (rows: WordRule[], on: boolean) => {
    const todo = rows.filter((r) => r.active !== on);
    if (todo.length === 0) return;
    setRequest({
      title: on ? (todo.length === 1 ? "Turn this rule on?" : `Turn ${todo.length} rules on?`) : (todo.length === 1 ? "Turn this rule off?" : `Turn ${todo.length} rules off?`),
      body: todo.length === 1 ? `“${todo[0].pattern}” (${ACTION_TEXT[todo[0].action].label})` : todo.slice(0, 6).map((r) => `“${r.pattern}”`).join(", ") + (todo.length > 6 ? ` and ${todo.length - 6} more` : ""),
      button: on ? "Turn on" : "Turn off", doneText: todo.length === 1 ? `“${todo[0].pattern}” ${on ? "on" : "off"}` : `${todo.length} rules ${on ? "on" : "off"}`,
      run: async (reason) => {
        for (const r of todo) await adminMessageCall("message_admin_word_set_active", { _id: r.id, _active: on, _reason: reason });
        t.setSelected(new Set());
        setOpen((o) => (o && todo.some((r) => r.id === o.id) ? { ...o, active: on } : o));
        await refresh();
      },
    });
  };

  const columns = useMemo<DTColumn<WordRule>[]>(() => [
    { key: "word", header: "Word or phrase", sortKey: "word", cell: (r) => <span className={`font-medium ${r.active ? "" : "text-muted-foreground line-through"}`}>{r.pattern}</span> },
    { key: "kind", header: "Kind", sortKey: "kind", cell: (r) => <span className="text-sm">{CATEGORY_TEXT[r.category] ?? r.category}</span> },
    { key: "action", header: "What happens", sortKey: "action", cell: (r) => <Badge variant={ACTION_TEXT[r.action].variant}>{ACTION_TEXT[r.action].label}</Badge> },
    { key: "lang", header: "Language", cell: (r) => <span className="text-sm text-muted-foreground">{r.lang ?? "any"}</span> },
    { key: "added", header: "Added", sortKey: "added", className: "whitespace-nowrap", cell: (r) => <span className="text-sm text-muted-foreground">{added(r.added_at)}</span> },
    { key: "status", header: "On", sortKey: "status", className: "w-16", cell: (r) => (
      <span onClick={(e) => e.stopPropagation()}><Switch checked={r.active} onCheckedChange={(on) => askActive([r], on)} aria-label={`${r.pattern} active`} /></span>) },
    // eslint-disable-next-line react-hooks/exhaustive-deps -- askActive only reads state through setRequest
  ], []);

  const exportCsv = () => downloadCsv("word-guard.csv", ["Word or phrase", "Kind", "What happens", "Language", "On", "Added"],
    t.filtered.map((r) => [r.pattern, CATEGORY_TEXT[r.category] ?? r.category, ACTION_TEXT[r.action].label, r.lang ?? "any", r.active ? "on" : "off", r.added_at]));

  return (
    <div className="space-y-3" data-testid="messages-words">
      <p className="text-xs text-muted-foreground">
        Every message is checked against this list before it is sent, automatically. Block refuses it; Help lets it through and shows the sender a helpline.
        Add any word you want stopped (for example political words) as Block. New accounts also cannot send web links for their first 7 days.
      </p>
      <AdminDataTable<WordRule>
        testId="messages-words-table"
        rows={t.view}
        rowKey={(r) => String(r.id)}
        columns={columns}
        tabs={[
          { key: "all", label: "All words", count: counts.all }, { key: "block", label: "Block", count: counts.block },
          { key: "help", label: "Help", count: counts.help }, { key: "on", label: "On", count: counts.on }, { key: "off", label: "Off", count: counts.off },
        ]}
        tab={tab}
        onTab={(k) => { setTab(k as Tab); t.setPage(0); }}
        search={t.search}
        onSearch={t.setSearch}
        searchPlaceholder="Search word, kind or language"
        toolbar={(
          <>
            <select className={selectClass} value={kind} onChange={(e) => { setKind(e.target.value); t.setPage(0); }} aria-label="Filter by kind">
              <option value="all">All kinds</option>
              {Object.entries(CATEGORY_TEXT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
            <Button variant="outline" size="sm" className="h-9" onClick={exportCsv} disabled={t.total === 0}><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export</Button>
            <Button size="sm" className="h-9" onClick={() => setAdding(true)} data-testid="word-add-open"><Plus className="mr-1 h-4 w-4" aria-hidden="true" />Add a word</Button>
          </>
        )}
        sort={t.sort}
        onSort={t.onSort}
        selected={t.selected}
        onSelectedChange={t.setSelected}
        bulkBar={() => (
          <>
            <Button size="sm" variant="outline" onClick={() => askActive(t.pickedRows, true)}><Power className="mr-1 h-4 w-4" aria-hidden="true" />Turn on</Button>
            <Button size="sm" variant="outline" onClick={() => askActive(t.pickedRows, false)}><PowerOff className="mr-1 h-4 w-4" aria-hidden="true" />Turn off</Button>
          </>
        )}
        page={t.page}
        pageSize={t.pageSize}
        total={t.total}
        onPage={t.setPage}
        onPageSize={t.setPageSize}
        loading={words.isLoading}
        error={words.error ? "Could not read the word list." : null}
        emptyText={t.search ? `No word matches “${t.search}”.` : "No words here."}
        onRowClick={setOpen}
        phoneCard={(r) => (
          <div className="flex items-center gap-2">
            <div className="min-w-0 flex-1">
              <p className={`truncate font-medium ${r.active ? "" : "text-muted-foreground line-through"}`}>{r.pattern}</p>
              <p className="text-xs text-muted-foreground">{CATEGORY_TEXT[r.category] ?? r.category} · {r.lang ?? "any"} · {r.active ? "on" : "off"}</p>
            </div>
            <Badge variant={ACTION_TEXT[r.action].variant}>{ACTION_TEXT[r.action].label}</Badge>
          </div>
        )}
      />

      <AdminSidePanel
        open={!!open} onClose={() => setOpen(null)} testId="word-side-panel"
        title={open ? <span className={open.active ? "" : "line-through"}>{open.pattern}</span> : ""}
        subtitle={open ? `${CATEGORY_TEXT[open.category] ?? open.category} · ${open.lang ?? "any language"}` : undefined}
        footer={open && (
          <Button variant={open.active ? "outline" : "default"} onClick={() => askActive([open], !open.active)}>
            {open.active ? <><PowerOff className="mr-1 h-4 w-4" aria-hidden="true" />Turn off</> : <><Power className="mr-1 h-4 w-4" aria-hidden="true" />Turn on</>}
          </Button>
        )}
      >
        {open && (
          <>
            <PanelField label="What happens"><Badge variant={ACTION_TEXT[open.action].variant}>{ACTION_TEXT[open.action].label}</Badge><p className="mt-1.5 text-muted-foreground">{ACTION_TEXT[open.action].blurb}</p></PanelField>
            <PanelField label="Status">{open.active ? "On — checked on every message" : "Off — not checked"}</PanelField>
            <PanelField label="Matches">Whole words only, any capital letters.</PanelField>
            <PanelField label="Added">{added(open.added_at)}</PanelField>
          </>
        )}
      </AdminSidePanel>

      <AdminSidePanel
        open={adding} onClose={() => setAdding(false)} testId="word-add-panel" title="Add a word or phrase" subtitle="It is checked on every message from now on."
        footer={<Button onClick={askAdd} disabled={pattern.trim().length < 2}>Add</Button>}
      >
        <label className="block space-y-1 text-xs"><span className="font-medium">Word or phrase</span>
          <Input value={pattern} onChange={(e) => setPattern(e.target.value)} maxLength={200} placeholder="2 to 200 characters" /></label>
        <label className="block space-y-1 text-xs"><span className="font-medium">Kind</span>
          <select className={`${selectClass} w-full`} value={category} onChange={(e) => setCategory(e.target.value)} aria-label="Kind of word">
            {Object.entries(CATEGORY_TEXT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select></label>
        <label className="block space-y-1 text-xs"><span className="font-medium">What happens</span>
          <select className={`${selectClass} w-full`} value={action} onChange={(e) => setAction(e.target.value as WordRule["action"])} aria-label="What happens">
            {(Object.keys(ACTION_TEXT) as WordRule["action"][]).map((k) => <option key={k} value={k}>{ACTION_TEXT[k].label}</option>)}
          </select></label>
        <p className="text-xs text-muted-foreground">{ACTION_TEXT[action].blurb}</p>
        <label className="block w-24 space-y-1 text-xs"><span className="font-medium">Language</span>
          <Input value={lang} onChange={(e) => setLang(e.target.value)} maxLength={8} aria-label="Language code" /></label>
      </AdminSidePanel>

      <ReasonDialog request={request} onClose={() => setRequest(null)} />
    </div>
  );
}

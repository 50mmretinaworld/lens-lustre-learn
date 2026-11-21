/**
 * Admin → Messages → "History": every change an admin made here (mode, groups, list, member rules, word list),
 * on the shared admin table: tabs per area with counts, search (who / about / reason), sort, export, and a side
 * panel with the whole entry. Reading a member's message box is NOT logged (Owner order 21 Nov 2026).
 */
import { useMemo, useState } from "react";
import { Download } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import AdminDataTable, { type DTColumn } from "@/components/admin/AdminDataTable";
import AdminSidePanel, { PanelField } from "@/components/admin/AdminSidePanel";
import { cmpDate, cmpText, downloadCsv, useClientTable } from "@/components/admin/useClientTable";
import type { ControlLogRow } from "@/hooks/admin/useAdminMessages";

export const AREA_TEXT: Record<string, string> = {
  mode: "Who can message", groups: "Groups", list: "Member list", member_rule: "Member rules",
  word_rule: "Word list", review: "Held message", lookup: "Chat list looked up (old)",
};
const when = (iso: string) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
};

export default function HistoryPanel({ log, me, names }: { log: ControlLogRow[]; me: string | null; names: Map<string, string> }) {
  const [area, setArea] = useState("all");
  const [open, setOpen] = useState<ControlLogRow | null>(null);
  const actor = (l: ControlLogRow) => (l.actor === me ? "You" : l.actor ? (names.get(l.actor) ?? l.actor.slice(0, 8)) : "System");
  const about = (l: ControlLogRow) => (l.user_id ? (names.get(l.user_id) ?? l.user_id.slice(0, 8)) : "");
  const change = (l: ControlLogRow) => (l.old || l.new ? `${l.old ?? "—"} → ${l.new ?? "—"}` : "");

  const areas = useMemo(() => [...new Set(log.map((l) => l.area))], [log]);
  const t = useClientTable<ControlLogRow>(log, {
    rowKey: (l) => `${l.at}|${l.area}|${l.user_id ?? ""}|${l.reason}`,
    searchText: (l) => `${actor(l)} ${about(l)} ${l.reason} ${change(l)} ${AREA_TEXT[l.area] ?? l.area}`,
    sorts: {
      when: (a, b) => cmpDate(a.at, b.at), area: (a, b) => cmpText(AREA_TEXT[a.area] ?? a.area, AREA_TEXT[b.area] ?? b.area),
      who: (a, b) => cmpText(actor(a), actor(b)),
    },
    defaultSort: { key: "when", dir: "desc" },
    keep: (l) => area === "all" || l.area === area,
  });

  const columns: DTColumn<ControlLogRow>[] = [
    { key: "when", header: "When", sortKey: "when", className: "whitespace-nowrap", cell: (l) => <span className="text-sm text-muted-foreground">{when(l.at)}</span> },
    { key: "area", header: "Area", sortKey: "area", cell: (l) => <Badge variant="secondary">{AREA_TEXT[l.area] ?? l.area}</Badge> },
    { key: "who", header: "Done by", sortKey: "who", cell: (l) => <span className="font-medium">{actor(l)}</span> },
    { key: "about", header: "About", cell: (l) => <span className="text-sm">{about(l) || "—"}</span> },
    { key: "change", header: "Change", className: "max-w-[260px]", cell: (l) => <span className="line-clamp-2 text-sm text-muted-foreground">{change(l) || "—"}</span> },
    { key: "reason", header: "Reason", className: "max-w-[280px]", cell: (l) => <span className="line-clamp-2 text-sm">“{l.reason}”</span> },
  ];

  return (
    <div className="space-y-3" data-testid="messages-history">
      <p className="text-xs text-muted-foreground">Kept for a year. Reading a member's message box is not logged.</p>
      <AdminDataTable<ControlLogRow>
        testId="messages-history-table" rows={t.view} rowKey={(l) => `${l.at}|${l.area}|${l.user_id ?? ""}|${l.reason}`} columns={columns}
        tabs={[{ key: "all", label: "Everything", count: log.length }, ...areas.map((a) => ({ key: a, label: AREA_TEXT[a] ?? a, count: log.filter((l) => l.area === a).length }))]}
        tab={area} onTab={(k) => { setArea(k); t.setPage(0); }}
        search={t.search} onSearch={t.setSearch} searchPlaceholder="Search who, about, reason or change"
        toolbar={<Button variant="outline" size="sm" className="h-9" disabled={t.total === 0}
          onClick={() => downloadCsv("message-history.csv", ["When", "Area", "Done by", "About", "From", "To", "Reason"],
            t.filtered.map((l) => [l.at, AREA_TEXT[l.area] ?? l.area, actor(l), about(l), l.old, l.new, l.reason]))}><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export</Button>}
        sort={t.sort} onSort={t.onSort}
        page={t.page} pageSize={t.pageSize} total={t.total} onPage={t.setPage} onPageSize={t.setPageSize}
        emptyText={t.search ? `Nothing matches “${t.search}”.` : "No changes yet."}
        onRowClick={setOpen}
        phoneCard={(l) => (
          <div className="space-y-1">
            <div className="flex items-center gap-2"><Badge variant="secondary">{AREA_TEXT[l.area] ?? l.area}</Badge><span className="text-xs text-muted-foreground">{when(l.at)}</span></div>
            <p className="text-sm"><b>{actor(l)}</b>{about(l) ? <> about <b>{about(l)}</b></> : null}</p>
            <p className="text-xs">“{l.reason}”</p>
          </div>
        )}
      />
      <AdminSidePanel open={!!open} onClose={() => setOpen(null)} testId="history-side-panel"
        title={open ? (AREA_TEXT[open.area] ?? open.area) : ""} subtitle={open ? `${actor(open)} · ${when(open.at)}` : undefined}>
        {open && (
          <>
            {about(open) && <PanelField label="About">{about(open)}</PanelField>}
            {change(open) && <PanelField label="Change">{change(open)}</PanelField>}
            <PanelField label="Reason">“{open.reason}”</PanelField>
          </>
        )}
      </AdminSidePanel>
    </div>
  );
}

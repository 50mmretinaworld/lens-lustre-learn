/**
 * ONE modern admin table (Owner order 21 Nov 2026: "advance, pro level, user friendly" — and one shared
 * system, never page by page). Same look and behaviour as Admin → Users:
 *   · status tabs with counts · search (press "/" to jump to it) · sortable column heads (click again to flip)
 *   · tick-boxes (row, whole page) with a floating bulk bar · rows open on click or Enter
 *   · pager with rows per page · loading / empty / error states · phone: cards instead of columns
 * It only DISPLAYS. The page decides what search / sort / tabs / paging mean (SQL for big lists, the array
 * for small ones) and what a bulk action does.
 */
import { useEffect, useRef, useState, type ReactNode } from "react";
import { ArrowDown, ArrowUp, ArrowUpDown, ChevronLeft, ChevronRight, Loader2, Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useIsMobile } from "@/hooks/core/use-mobile";
import { cn } from "@/lib/utils";

export interface DTColumn<T> {
  key: string;
  header: string;
  /** Click on the head sorts by this key (the page maps it to its own sort). Leave out for a plain column. */
  sortKey?: string;
  className?: string;
  cell: (row: T) => ReactNode;
}
export interface DTTab { key: string; label: string; count?: number | null; /** amber count when above 0 */ warn?: boolean }
export interface DTSort { key: string; dir: "asc" | "desc" }

export interface DataTableProps<T> {
  rows: T[];
  rowKey: (row: T) => string;
  columns: DTColumn<T>[];
  testId?: string;
  tabs?: DTTab[];
  tab?: string;
  onTab?: (key: string) => void;
  search?: string;
  onSearch?: (text: string) => void;
  searchPlaceholder?: string;
  /** extra controls on the right of the search row (export, add, …) */
  toolbar?: ReactNode;
  sort?: DTSort | null;
  onSort?: (sortKey: string) => void;
  selected?: ReadonlySet<string>;
  onSelectedChange?: (next: Set<string>) => void;
  /** shown in the floating bar while something is ticked */
  bulkBar?: (selectedCount: number) => ReactNode;
  page?: number;
  pageSize?: number;
  total?: number;
  onPage?: (page: number) => void;
  onPageSize?: (size: number) => void;
  loading?: boolean;
  fetching?: boolean;
  error?: string | null;
  emptyText?: string;
  onRowClick?: (row: T) => void;
  /** phone layout; without it the first two columns are stacked */
  phoneCard?: (row: T) => ReactNode;
  /** show the card layout below this window width (px) as well, for tables with many columns */
  cardsBelow?: number;
}

function SortHead({ col, sort, onSort }: { col: DTColumn<unknown>; sort?: DTSort | null; onSort?: (k: string) => void }) {
  if (!col.sortKey || !onSort) return <TableHead className={col.className}>{col.header}</TableHead>;
  const on = sort?.key === col.sortKey;
  const Icon = !on ? ArrowUpDown : sort?.dir === "asc" ? ArrowUp : ArrowDown;
  return (
    <TableHead className={col.className} aria-sort={on ? (sort?.dir === "asc" ? "ascending" : "descending") : "none"}>
      <button type="button" onClick={() => onSort(col.sortKey as string)} className={cn("inline-flex items-center gap-1 rounded px-1 py-0.5 -mx-1 hover:bg-muted", on && "text-foreground")}>
        {col.header}<Icon className={cn("h-3.5 w-3.5", !on && "text-muted-foreground/60")} aria-hidden="true" />
      </button>
    </TableHead>
  );
}

export default function AdminDataTable<T>(p: DataTableProps<T>) {
  const [narrow, setNarrow] = useState(false);
  const cardsBelow = p.cardsBelow;
  useEffect(() => {
    if (!cardsBelow || typeof window === "undefined" || !window.matchMedia) return;
    const mq = window.matchMedia(`(max-width: ${cardsBelow - 1}px)`);
    const on = () => setNarrow(mq.matches);
    on();
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, [cardsBelow]);
  const isPhone = useIsMobile() || narrow;
  const searchRef = useRef<HTMLInputElement>(null);
  const selectable = !!p.onSelectedChange;
  const selected = p.selected ?? new Set<string>();
  const total = p.total ?? p.rows.length;
  const pageSize = p.pageSize ?? p.rows.length;
  const page = p.page ?? 0;
  const pageCount = Math.max(1, Math.ceil(total / Math.max(pageSize, 1)));
  const from = total === 0 ? 0 : page * pageSize + 1;
  const to = Math.min(total, page * pageSize + p.rows.length);

  // "/" jumps to the search box (as in Admin → Users)
  useEffect(() => {
    if (!p.onSearch) return;
    const onKey = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null;
      if (e.key === "/" && !(el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable))) { e.preventDefault(); searchRef.current?.focus(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [p.onSearch]);

  const keys = p.rows.map(p.rowKey);
  const pageAll = keys.length > 0 && keys.every((k) => selected.has(k));
  const pageSome = !pageAll && keys.some((k) => selected.has(k));
  const toggleRow = (k: string) => { const n = new Set(selected); if (n.has(k)) n.delete(k); else n.add(k); p.onSelectedChange?.(n); };
  const togglePage = () => { const n = new Set(selected); if (pageAll) keys.forEach((k) => n.delete(k)); else keys.forEach((k) => n.add(k)); p.onSelectedChange?.(n); };

  const rowKeyDown = (e: React.KeyboardEvent, row: T) => {
    if (!p.onRowClick) return;
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); p.onRowClick(row); }
    else if (e.key === "ArrowDown") { e.preventDefault(); ((e.currentTarget as HTMLElement).nextElementSibling as HTMLElement | null)?.focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); ((e.currentTarget as HTMLElement).previousElementSibling as HTMLElement | null)?.focus(); }
  };

  return (
    <div className="space-y-3" data-testid={p.testId ?? "admin-table"}>
      {p.tabs && p.tabs.length > 0 && (
        <div className="-mx-1 flex gap-1.5 overflow-x-auto px-1 pb-1" role="tablist" aria-label="Filter">
          {p.tabs.map((t) => {
            const on = p.tab === t.key;
            return (
              <button key={t.key} type="button" role="tab" aria-selected={on} data-testid={`tab-${t.key}`} onClick={() => p.onTab?.(t.key)}
                className={cn("inline-flex min-h-9 shrink-0 items-center gap-2 rounded-full border px-3 text-sm transition-colors",
                  on ? "border-primary bg-primary text-primary-foreground" : "border-border bg-card hover:border-primary/60")}>
                {t.label}
                {t.count != null && (
                  <span className={cn("rounded-full px-1.5 text-xs tabular-nums", on ? "bg-primary-foreground/20" : "bg-muted text-muted-foreground",
                    !on && t.warn && t.count > 0 && "bg-amber-500/15 text-amber-700 dark:text-amber-300")}>{t.count.toLocaleString()}</span>
                )}
              </button>
            );
          })}
        </div>
      )}

      {(p.onSearch || p.toolbar) && (
        <div className="flex flex-col gap-2 md:flex-row md:items-center">
          {p.onSearch && (
            <div className="relative min-w-0 flex-1 md:min-w-[220px]">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
              <Input ref={searchRef} value={p.search ?? ""} onChange={(e) => p.onSearch?.(e.target.value)} placeholder={p.searchPlaceholder ?? "Search"} className="h-9 pl-9 pr-16" aria-label={p.searchPlaceholder ?? "Search"} />
              {p.search ? (
                <button type="button" className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-muted-foreground hover:text-foreground" aria-label="Clear search" onClick={() => p.onSearch?.("")}><X className="h-4 w-4" /></button>
              ) : !isPhone && (
                <kbd className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 rounded border border-border px-1.5 text-[10px] text-muted-foreground">/</kbd>
              )}
            </div>
          )}
          {p.toolbar && <div className="flex flex-wrap items-center gap-2">{p.toolbar}</div>}
        </div>
      )}

      {p.loading ? (
        <div className="flex justify-center py-16"><Loader2 className="h-5 w-5 animate-spin text-muted-foreground" aria-label="Loading" /></div>
      ) : p.error ? (
        <p className="rounded-lg border border-destructive/40 p-4 text-sm text-destructive" role="alert">{p.error}</p>
      ) : p.rows.length === 0 ? (
        <div className="rounded-xl border border-dashed border-border py-14 text-center text-sm text-muted-foreground">{p.emptyText ?? "Nothing here."}</div>
      ) : isPhone ? (
        <ul className={cn("space-y-2 transition-opacity", p.fetching && "opacity-60")}>
          {p.rows.map((row) => {
            const k = p.rowKey(row);
            return (
              <li key={k} data-testid="table-row" className={cn("rounded-xl border bg-card p-3", selected.has(k) ? "border-primary" : "border-border")}>
                <div className="flex items-start gap-3">
                  {selectable && <Checkbox checked={selected.has(k)} onCheckedChange={() => toggleRow(k)} aria-label="Select" className="mt-2.5" />}
                  <button type="button" className="min-w-0 flex-1 text-left" onClick={() => p.onRowClick?.(row)}>
                    {p.phoneCard ? p.phoneCard(row) : <div className="space-y-1">{p.columns.slice(0, 2).map((c) => <div key={c.key}>{c.cell(row)}</div>)}</div>}
                  </button>
                </div>
              </li>
            );
          })}
        </ul>
      ) : (
        <div className={cn("overflow-x-auto rounded-xl border border-border bg-card transition-opacity", p.fetching && "opacity-60")}>
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                {selectable && (
                  <TableHead className="w-10">
                    <Checkbox checked={pageAll ? true : pageSome ? "indeterminate" : false} onCheckedChange={togglePage} aria-label="Select this page" />
                  </TableHead>
                )}
                {p.columns.map((c) => <SortHead key={c.key} col={c as DTColumn<unknown>} sort={p.sort} onSort={p.onSort} />)}
              </TableRow>
            </TableHeader>
            <TableBody>
              {p.rows.map((row) => {
                const k = p.rowKey(row);
                return (
                  <TableRow key={k} data-testid="table-row" data-state={selected.has(k) ? "selected" : undefined} tabIndex={p.onRowClick ? 0 : undefined}
                    className={cn(p.onRowClick && "cursor-pointer focus-visible:bg-muted/60 focus-visible:outline-none", "data-[state=selected]:bg-primary/10")}
                    onClick={() => p.onRowClick?.(row)} onKeyDown={(e) => rowKeyDown(e, row)}>
                    {selectable && (
                      <TableCell onClick={(e) => e.stopPropagation()}><Checkbox checked={selected.has(k)} onCheckedChange={() => toggleRow(k)} aria-label="Select" /></TableCell>
                    )}
                    {p.columns.map((c) => <TableCell key={c.key} className={c.className}>{c.cell(row)}</TableCell>)}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      {p.onPage && total > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-3 px-1 text-sm">
          <div className="flex items-center gap-2 text-muted-foreground">
            {p.onPageSize && (
              <>
                <span className="hidden sm:inline">Rows per page</span>
                <Select value={String(pageSize)} onValueChange={(v) => p.onPageSize?.(Number(v))}>
                  <SelectTrigger className="h-8 w-[72px]" aria-label="Rows per page"><SelectValue /></SelectTrigger>
                  <SelectContent>{[25, 50, 100].map((s) => <SelectItem key={s} value={String(s)}>{s}</SelectItem>)}</SelectContent>
                </Select>
              </>
            )}
          </div>
          <div className="flex items-center gap-3">
            <span className="tabular-nums text-muted-foreground" data-testid="table-range">{from.toLocaleString()}–{to.toLocaleString()} of {total.toLocaleString()}</span>
            <div className="flex items-center gap-1">
              <Button variant="outline" size="icon" className="h-9 w-9" disabled={page === 0} aria-label="Previous page" onClick={() => p.onPage?.(page - 1)}><ChevronLeft className="h-4 w-4" /></Button>
              <span className="min-w-[72px] text-center tabular-nums">Page {page + 1} / {pageCount.toLocaleString()}</span>
              <Button variant="outline" size="icon" className="h-9 w-9" disabled={page >= pageCount - 1} aria-label="Next page" onClick={() => p.onPage?.(page + 1)}><ChevronRight className="h-4 w-4" /></Button>
            </div>
          </div>
        </div>
      )}

      {selectable && selected.size > 0 && p.bulkBar && (
        <div className="fixed inset-x-3 bottom-4 z-40 mx-auto flex max-w-3xl flex-wrap items-center gap-2 rounded-xl border border-border bg-popover p-2 pl-4 shadow-2xl" role="toolbar" aria-label="Selected" data-testid="table-bulk-bar">
          <span className="mr-1 text-sm font-medium">{selected.size} selected</span>
          {p.bulkBar(selected.size)}
          <Button size="sm" variant="ghost" className="ml-auto" onClick={() => p.onSelectedChange?.(new Set())} aria-label="Clear selection"><X className="h-4 w-4" /></Button>
        </div>
      )}
    </div>
  );
}

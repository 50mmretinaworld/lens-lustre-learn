/**
 * The table state for SMALL lists the page already holds in memory (word list, reports, history, the "who can
 * message" list): search, sort, paging and the ticked rows, in one place so every such table behaves the same.
 * Big lists (members, broadcasts) filter on the server instead and do not use this.
 */
import { useEffect, useMemo, useState } from "react";
import type { DTSort } from "@/components/admin/AdminDataTable";

export interface ClientTableOptions<T> {
  /** the text a search looks in (lower-cased by the hook) */
  searchText: (row: T) => string;
  /** one compare function per sort key; the key is the column's sortKey */
  sorts: Record<string, (a: T, b: T) => number>;
  defaultSort: DTSort;
  rowKey: (row: T) => string;
  /** rows kept by the active tab / filters */
  keep?: (row: T) => boolean;
}

export function useClientTable<T>(rows: T[], o: ClientTableOptions<T>) {
  const [search, setSearch] = useState("");
  const [sort, setSort] = useState<DTSort>(o.defaultSort);
  const [page, setPage] = useState(0);
  const [pageSize, setPageSize] = useState(25);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const { searchText, sorts, keep } = o;
  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase();
    const cmp = sorts[sort.key];
    const out = rows.filter((r) => (!keep || keep(r)) && (!needle || searchText(r).toLowerCase().includes(needle)));
    if (cmp) out.sort((a, b) => (sort.dir === "asc" ? cmp(a, b) : cmp(b, a)));
    return out;
  }, [rows, search, sort, keep, searchText, sorts]);

  // the page and the ticks follow the data: a smaller list never leaves you on an empty page or with a hidden tick
  const pageCount = Math.max(1, Math.ceil(filtered.length / pageSize));
  useEffect(() => { if (page > pageCount - 1) setPage(pageCount - 1); }, [page, pageCount]);
  useEffect(() => {
    setSelected((s) => {
      if (s.size === 0) return s;
      const alive = new Set(rows.map(o.rowKey));
      const next = new Set([...s].filter((k) => alive.has(k)));
      return next.size === s.size ? s : next;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- rowKey is a stable accessor of the page
  }, [rows]);

  const view = useMemo(() => filtered.slice(page * pageSize, page * pageSize + pageSize), [filtered, page, pageSize]);

  return {
    view, filtered, total: filtered.length,
    search, setSearch: (v: string) => { setSearch(v); setPage(0); },
    sort, onSort: (k: string) => { setSort((s) => (s.key === k ? { key: k, dir: s.dir === "asc" ? "desc" : "asc" } : { key: k, dir: "asc" })); setPage(0); },
    page, setPage, pageSize, setPageSize: (n: number) => { setPageSize(n); setPage(0); },
    selected, setSelected,
    /** the ticked rows that are still in the list */
    pickedRows: rows.filter((r) => selected.has(o.rowKey(r))),
  };
}

/** Compare helpers for the `sorts` map. */
export const cmpText = (a: string | null | undefined, b: string | null | undefined) => (a ?? "").toLowerCase().localeCompare((b ?? "").toLowerCase());
export const cmpNum = (a: number | null | undefined, b: number | null | undefined) => (a ?? 0) - (b ?? 0);
/** ISO date strings; a missing date counts as the oldest. */
export const cmpDate = (a: string | null | undefined, b: string | null | undefined) => (a ? Date.parse(a) || 0 : 0) - (b ? Date.parse(b) || 0 : 0);

/** One download of a table as CSV (what is on screen after search and filters, not only the current page). */
export function downloadCsv(filename: string, header: string[], lines: unknown[][]): void {
  const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const text = [header.map(esc).join(","), ...lines.map((l) => l.map(esc).join(","))].join("\n");
  const url = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url; a.download = filename; a.click();
  URL.revokeObjectURL(url);
}

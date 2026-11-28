/**
 * M11 · Admin → Messages → "Message boxes": find any member in a modern table (search name / @username /
 * e-mail, filter, sort, page) and open THEIR message box — the member's own screens, read-only, for as long
 * as you like. Nothing is asked, nothing is logged, no alarm (Owner order 21 Nov 2026). Super admins only.
 */
import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, Download, Eye, Flag } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import AdminDataTable, { type DTColumn, type DTSort } from "@/components/admin/AdminDataTable";
import { MemberAvatar } from "@/components/admin/users/memberUi";
import AutoBadge from "@/components/AutoBadge";
import ConversationList from "@/components/messages/ConversationList";
import ChatPane from "@/components/messages/ChatPane";
import ExportChatButton from "./ExportChatButton";
import { ViewAsProvider } from "@/components/messages/viewAs";
import {
  useMessageMembers, type MemberFilter, type MemberSortKey, type MsgMember,
} from "@/hooks/admin/useAdminMessages";

const when = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};
const joined = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
};
const nameOf = (m: Pick<MsgMember, "full_name" | "username" | "user_id">) => m.full_name || (m.username ? `@${m.username}` : m.user_id.slice(0, 8));

/** "Chatting with": the people (not message lines) — their latest 3 as photos + names, then how many more. One chat = one person. */
function ChattingWith({ m }: { m: MsgMember }) {
  if (m.chats === 0) return <span className="text-sm text-muted-foreground">No chats yet</span>;
  const more = Math.max(0, m.chats - m.chatting_with.length);
  return (
    <div className="flex items-center gap-2" data-testid="chatting-with">
      <span className="flex -space-x-2">
        {m.chatting_with.map((w, i) => <MemberAvatar key={`${w.user_id ?? w.name}-${i}`} m={{ avatar_url: w.avatar_url, full_name: w.name, email: null }} size={26} />)}
      </span>
      <span className="min-w-0 text-sm">
        <span className="block truncate">{m.chatting_with.map((w) => w.name).join(", ")}{more > 0 ? ` +${more} more` : ""}</span>
        <span className="block text-[11px] text-muted-foreground">{m.chats} {m.chats === 1 ? "person" : "people"}</span>
      </span>
    </div>
  );
}

/** The member's message box: their list on the left, their chat on the right, read-only. */
function BoxViewer({ member, onBack }: { member: MsgMember; onBack: () => void }) {
  const [chatId, setChatId] = useState<string | null>(null);
  const name = nameOf(member);
  return (
    <div className="space-y-3" data-testid="messages-box-viewer">
      <div className="flex flex-wrap items-center gap-3 rounded-xl border border-border bg-card p-2.5">
        <Button variant="outline" size="sm" onClick={onBack}><ArrowLeft className="mr-1 h-4 w-4" aria-hidden="true" />All members</Button>
        <MemberAvatar m={member} size={36} />
        <div className="min-w-0 flex-1">
          <p className="flex items-center gap-1 text-sm font-semibold"><span className="truncate">{name}</span><AutoBadge userId={member.user_id} only="verified" /></p>
          <p className="truncate text-xs text-muted-foreground">{member.email ?? ""}{member.username ? ` · @${member.username}` : ""}</p>
        </div>
        {chatId && <ExportChatButton userId={member.user_id} conversationId={chatId} />}
        <Badge variant="secondary"><Eye className="mr-1 h-3 w-3" aria-hidden="true" />Viewing their message box · read only</Badge>
      </div>
      <ViewAsProvider value={{ userId: member.user_id, name }}>
        <div className="flex h-[min(72vh,760px)] min-h-[480px] overflow-hidden rounded-2xl border border-border bg-background shadow-sm">
          <section aria-label="Chats" className={`${chatId ? "hidden lg:block" : "block"} h-full w-full shrink-0 lg:w-[340px] lg:border-r lg:border-border`}>
            <ConversationList activeId={chatId} onOpen={setChatId} />
          </section>
          <section className={`${chatId ? "block" : "hidden lg:block"} h-full min-w-0 flex-1`}>
            {chatId
              ? <ChatPane key={chatId} conversationId={chatId} userId={null} onBack={() => setChatId(null)} />
              : <div className="grid h-full place-items-center px-8 text-center text-sm text-muted-foreground">Pick a chat on the left to read it as {name} sees it.</div>}
          </section>
        </div>
      </ViewAsProvider>
    </div>
  );
}

export default function MembersPanel() {
  const [searchText, setSearchText] = useState("");
  const [q, setQ] = useState("");
  const [filter, setFilter] = useState<MemberFilter>("all");
  const [sort, setSort] = useState<DTSort>({ key: "last", dir: "desc" });
  const [page, setPage] = useState(0);
  const [pageSize, setPageSize] = useState(25);
  const [open, setOpen] = useState<MsgMember | null>(null);

  useEffect(() => { const t = setTimeout(() => { setQ(searchText); setPage(0); }, 300); return () => clearTimeout(t); }, [searchText]);
  const res = useMessageMembers({ q, filter, sort: sort.key as MemberSortKey, dir: sort.dir, page, pageSize });
  const counts = res.data?.counts;
  const rows = res.data?.rows ?? [];

  const columns = useMemo<DTColumn<MsgMember>[]>(() => [
    { key: "member", header: "Member", sortKey: "name", className: "min-w-[190px] max-w-[230px] px-3", cell: (m) => (
      <div className="flex items-center gap-3">
        <MemberAvatar m={m} />
        <div className="min-w-0">
          <p className="flex items-center gap-1 truncate font-medium"><span className="truncate">{nameOf(m)}</span><AutoBadge userId={m.user_id} only="verified" /></p>
          <p className="truncate text-xs text-muted-foreground">{m.email ?? "—"}{m.username ? ` · @${m.username}` : ""}</p>
        </div>
      </div>) },
    { key: "chats", header: "Chatting with", sortKey: "chats", className: "min-w-[170px] max-w-[210px] px-3", cell: (m) => <ChattingWith m={m} /> },
    { key: "last", header: "Last message", sortKey: "last", className: "whitespace-nowrap px-3", cell: (m) => <span className="text-sm text-muted-foreground">{when(m.last_message_at)}</span> },
    { key: "reports", header: "Reports (30 d)", sortKey: "reports", className: "whitespace-nowrap px-3", cell: (m) => m.reports_30d > 0
      ? <Badge variant="destructive" className="whitespace-nowrap"><Flag className="mr-1 h-3 w-3" aria-hidden="true" />{m.reports_30d}</Badge>
      : <span className="text-muted-foreground">0</span> },
    { key: "status", header: "Status", className: "min-w-[110px] px-3", cell: (m) => (
      <div className="flex flex-col items-start gap-1">
        {m.is_admin && <Badge variant="secondary" className="whitespace-nowrap">Admin</Badge>}
        {m.listed && <Badge variant="outline" className="whitespace-nowrap">On the list</Badge>}
        {m.paused && <Badge variant="destructive" className="whitespace-nowrap">Paused</Badge>}
        {m.has_rules && !m.paused && <Badge variant="outline" className="whitespace-nowrap">Has rules</Badge>}
      </div>) },
    { key: "joined", header: "Joined", sortKey: "joined", className: "whitespace-nowrap px-3", cell: (m) => <span className="text-sm text-muted-foreground">{joined(m.joined_at)}</span> },
    { key: "open", header: "", className: "whitespace-nowrap px-3 text-right", cell: (m) => (
      <Button size="sm" variant="outline" className="shrink-0 whitespace-nowrap" onClick={(e) => { e.stopPropagation(); setOpen(m); }} data-testid="open-box"><Eye className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Open box</Button>) },
  ], []);

  if (open) return <BoxViewer member={open} onBack={() => setOpen(null)} />;

  const exportCsv = () => {
    const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const lines = [["Name", "Username", "E-mail", "People chatted with", "Last message", "Reports 30 d", "On the list", "Paused"].join(",")]
      .concat(rows.map((m) => [m.full_name, m.username, m.email, m.chats, m.last_message_at, m.reports_30d, m.listed, m.paused].map(esc).join(",")));
    const url = URL.createObjectURL(new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" }));
    const a = document.createElement("a");
    a.href = url; a.download = "message-members.csv"; a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="space-y-3" data-testid="messages-members">
      <p className="text-xs text-muted-foreground">
        Open any member's message box and read it exactly as they see it, for as long as you like. It is read only: you cannot send, and nothing you open is marked as read.
        Only super admins can do this.
      </p>
      <AdminDataTable<MsgMember>
        testId="messages-members-table"
        rows={rows}
        rowKey={(m) => m.user_id}
        columns={columns}
        tabs={[
          { key: "all", label: "All members", count: counts?.all ?? null },
          { key: "active", label: "With chats", count: counts?.active ?? null },
          { key: "reported", label: "Reported", count: counts?.reported ?? null, warn: true },
          { key: "paused", label: "Paused", count: counts?.paused ?? null, warn: true },
          { key: "listed", label: "On the list", count: counts?.listed ?? null },
        ]}
        tab={filter}
        onTab={(k) => { setFilter(k as MemberFilter); setPage(0); }}
        search={searchText}
        onSearch={setSearchText}
        searchPlaceholder="Search name, e-mail or @handle"
        toolbar={<Button variant="outline" size="sm" className="h-9" onClick={exportCsv} disabled={rows.length === 0}><Download className="mr-1 h-4 w-4" aria-hidden="true" />Export this page</Button>}
        sort={sort}
        onSort={(k) => { setSort((s) => (s.key === k ? { key: k, dir: s.dir === "asc" ? "desc" : "asc" } : { key: k, dir: k === "name" ? "asc" : "desc" })); setPage(0); }}
        page={page}
        pageSize={pageSize}
        total={res.data?.total ?? 0}
        onPage={setPage}
        onPageSize={(n) => { setPageSize(n); setPage(0); }}
        loading={res.isLoading}
        fetching={res.isFetching}
        error={res.error ? `Could not load members: ${(res.error as Error).message}` : null}
        emptyText={q ? `No member matches “${q}”.` : "No members here."}
        onRowClick={setOpen}
        cardsBelow={1280}
        phoneCard={(m) => (
          <div className="flex items-start gap-3">
            <MemberAvatar m={m} size={40} />
            <div className="min-w-0 flex-1 space-y-1">
              <p className="flex items-center gap-1 font-medium"><span className="truncate">{nameOf(m)}</span><AutoBadge userId={m.user_id} only="verified" /></p>
              <p className="truncate text-xs text-muted-foreground">{m.email ?? "—"}</p>
              <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
                <span>{m.chats === 0 ? "No chats yet" : `Chatting with ${m.chatting_with.map((w) => w.name).join(", ")}${m.chats > m.chatting_with.length ? ` +${m.chats - m.chatting_with.length} more` : ""}`}</span><span>· last {when(m.last_message_at)}</span>
                {m.reports_30d > 0 && <Badge variant="destructive">{m.reports_30d} reports</Badge>}
                {m.listed && <Badge variant="outline">On the list</Badge>}
                {m.paused && <Badge variant="destructive">Paused</Badge>}
              </div>
            </div>
          </div>
        )}
      />
    </div>
  );
}

/**
 * M8b · Admin → Messages → "Chats": pick a member, give a reason, see WHICH chats
 * they are in (who with, how many messages, last activity) — never the text.
 * Reading a chat is a second, separately logged step (ChatReader).
 */
import { useState } from "react";
import { Eye, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import ProfileTypeaheadPicker from "@/components/admin/ProfileTypeaheadPicker";
import ReasonDialog, { type ReasonRequest } from "./ReasonDialog";
import ChatReader from "./ChatReader";
import { adminMessageCall, parseMemberChats, type MemberChat } from "@/hooks/admin/useAdminMessages";

const when = (iso: string | null) => {
  if (!iso) return "no messages yet";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};

export default function ChatsPanel() {
  const [request, setRequest] = useState<ReasonRequest | null>(null);
  const [subject, setSubject] = useState<{ id: string; name: string } | null>(null);
  const [chats, setChats] = useState<MemberChat[] | null>(null);
  const [open, setOpen] = useState<string | null>(null);

  const askLookup = (p: { id: string; full_name: string | null }) => {
    const name = p.full_name || p.id.slice(0, 8);
    setRequest({
      title: `See ${name}'s chats?`,
      body: "You see who they chat with and how much — not the messages. The look-up is logged with your reason.",
      button: "Show chats",
      run: async (reason) => {
        const data = await adminMessageCall("admin_message_member_chats", { _user: p.id, _reason: reason });
        setSubject({ id: p.id, name });
        setChats(parseMemberChats(data));
      },
    });
  };

  return (
    <div className="space-y-3" data-testid="messages-chats">
      <p className="text-xs text-muted-foreground">
        Members’ chats are not private from the site team: any admin can read any chat, and every reading is logged (who, when, why).
        An unusual number of chats opened in one day raises an alarm to the Owner.
      </p>
      <ProfileTypeaheadPicker label="Member" hint="Search by name or e-mail. You give the reason on the next step." value={subject?.id ?? null}
        onChange={(p) => { if (p) askLookup({ id: p.id, full_name: p.full_name }); else { setSubject(null); setChats(null); } }} />
      {subject && chats && (
        <section aria-label="Chats" className="space-y-1">
          <h3 className="text-sm font-semibold">{subject.name} is in {chats.length} chat{chats.length === 1 ? "" : "s"}</h3>
          {chats.length === 0 ? <p className="text-sm text-muted-foreground">No chats.</p> : (
            <ul className="divide-y divide-border rounded-lg border border-border">
              {chats.map((c) => (
                <li key={c.conversation_id} className="flex flex-wrap items-center gap-2 p-2 text-sm" data-testid="messages-chat-row">
                  {c.kind === "group" && <Badge variant="outline"><Users className="mr-1 h-3 w-3" aria-hidden="true" />Group</Badge>}
                  <span className="font-medium">{c.kind === "group" ? (c.title || "Group") : (c.others[0]?.full_name || c.others[0]?.username || "Member")}</span>
                  {c.kind === "group" && <span className="text-xs text-muted-foreground">{c.others.length + 1} people</span>}
                  <span className="text-xs text-muted-foreground">{c.messages} message{c.messages === 1 ? "" : "s"} · last {when(c.last_message_at)}</span>
                  <Button size="sm" variant="outline" className="ml-auto" onClick={() => setOpen(c.conversation_id)}>
                    <Eye className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Read
                  </Button>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
      <ReasonDialog request={request} onClose={() => setRequest(null)} />
      {open && <ChatReader conversationId={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

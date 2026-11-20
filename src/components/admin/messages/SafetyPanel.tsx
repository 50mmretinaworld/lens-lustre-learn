/**
 * M8b · Admin → Messages → "Word guard" (the word list) and "Held" (messages the
 * guard kept back for review). English starter list only; more languages come
 * from the Owner / lawyer. Every change asks for a reason.
 */
import { useState } from "react";
import { Loader2, Eye } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import ReasonDialog, { type ReasonRequest } from "./ReasonDialog";
import ChatReader from "./ChatReader";
import {
  adminMessageCall, useMessageHeldQueue, useMessageWordRules, useRefreshAdminMessages, type WordRule,
} from "@/hooks/admin/useAdminMessages";

const ACTION_TEXT: Record<WordRule["action"], { label: string; blurb: string; variant: "destructive" | "outline" | "secondary" }> = {
  block: { label: "Block", blurb: "The message is not sent.", variant: "destructive" },
  hold: { label: "Hold", blurb: "Waits for you in the Held list.", variant: "outline" },
  help: { label: "Help", blurb: "Sent; the sender sees the helpline and you get an alarm.", variant: "secondary" },
};
const CATEGORY_TEXT: Record<string, string> = {
  abuse: "Abuse", threat: "Threats", political: "Political", self_harm: "Self-harm", abnormal: "Abnormal",
};
const selectClass = "h-9 rounded-md border border-border bg-background px-2 text-sm outline-none focus:border-primary";
const when = (iso: string | null) => {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};

export function WordsPanel() {
  const words = useMessageWordRules();
  const refresh = useRefreshAdminMessages();
  const [request, setRequest] = useState<ReasonRequest | null>(null);
  const [category, setCategory] = useState("abuse");
  const [action, setAction] = useState<WordRule["action"]>("block");
  const [pattern, setPattern] = useState("");
  const [lang, setLang] = useState("en");

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
        await refresh();
      },
    });
  };
  const askActive = (r: WordRule, on: boolean) => setRequest({
    title: on ? "Turn this rule on?" : "Turn this rule off?", body: `“${r.pattern}” (${ACTION_TEXT[r.action].label})`,
    button: on ? "Turn on" : "Turn off", doneText: `“${r.pattern}” ${on ? "on" : "off"}`,
    run: async (reason) => { await adminMessageCall("message_admin_word_set_active", { _id: r.id, _active: on, _reason: reason }); await refresh(); },
  });

  const rules = words.data ?? [];
  const byCategory = Object.keys(CATEGORY_TEXT).map((c) => ({ c, rows: rules.filter((r) => r.category === c) })).filter((g) => g.rows.length > 0);

  return (
    <div className="space-y-4" data-testid="messages-words">
      <p className="text-xs text-muted-foreground">
        Every message is checked against this list before it is sent. The strictest match wins: Block, then Hold, then Help.
      </p>
      <div className="flex flex-wrap items-end gap-2 rounded-lg border border-border p-3">
        <label className="space-y-1 text-xs"><span className="font-medium">Kind</span>
          <select className={selectClass} value={category} onChange={(e) => setCategory(e.target.value)} aria-label="Kind of word">
            {Object.entries(CATEGORY_TEXT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select></label>
        <label className="space-y-1 text-xs"><span className="font-medium">What happens</span>
          <select className={selectClass} value={action} onChange={(e) => setAction(e.target.value as WordRule["action"])} aria-label="What happens">
            {(Object.keys(ACTION_TEXT) as WordRule["action"][]).map((k) => <option key={k} value={k}>{ACTION_TEXT[k].label}</option>)}
          </select></label>
        <label className="min-w-[10rem] flex-1 space-y-1 text-xs"><span className="font-medium">Word or phrase</span>
          <Input value={pattern} onChange={(e) => setPattern(e.target.value)} maxLength={200} placeholder="2 to 200 characters" /></label>
        <label className="w-20 space-y-1 text-xs"><span className="font-medium">Language</span>
          <Input value={lang} onChange={(e) => setLang(e.target.value)} maxLength={8} aria-label="Language code" /></label>
        <Button onClick={askAdd} disabled={pattern.trim().length < 2}>Add</Button>
      </div>

      {words.isLoading && <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" aria-label="Loading" />}
      {words.error && <p className="text-sm text-destructive">Could not read the word list.</p>}
      {byCategory.map((g) => (
        <section key={g.c} aria-label={CATEGORY_TEXT[g.c]} className="space-y-1">
          <h4 className="text-xs font-semibold uppercase text-muted-foreground">{CATEGORY_TEXT[g.c]} ({g.rows.length})</h4>
          <ul className="divide-y divide-border rounded-lg border border-border">
            {g.rows.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center gap-2 p-2 text-sm" data-testid="messages-word-row">
                <span className={`font-medium ${r.active ? "" : "text-muted-foreground line-through"}`}>{r.pattern}</span>
                <Badge variant={ACTION_TEXT[r.action].variant}>{ACTION_TEXT[r.action].label}</Badge>
                {r.lang && <span className="text-xs text-muted-foreground">{r.lang}</span>}
                <span className="ml-auto"><Switch checked={r.active} onCheckedChange={(on) => askActive(r, on)} aria-label={`${r.pattern} active`} /></span>
              </li>
            ))}
          </ul>
        </section>
      ))}
      <ReasonDialog request={request} onClose={() => setRequest(null)} />
    </div>
  );
}

export function HeldPanel() {
  const held = useMessageHeldQueue();
  const [open, setOpen] = useState<string | null>(null);
  const rows = held.data ?? [];
  return (
    <div className="space-y-3" data-testid="messages-held">
      <p className="text-xs text-muted-foreground">
        Messages the word guard kept back. Nobody else has seen them. Reading one opens the chat and is logged; there you can deliver or reject it.
      </p>
      {held.isLoading && <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" aria-label="Loading" />}
      {held.error && <p className="text-sm text-destructive">Could not read the held messages.</p>}
      {held.data && rows.length === 0 && <p className="rounded-lg border border-dashed border-border p-4 text-center text-sm text-muted-foreground">Nothing is waiting.</p>}
      {rows.length > 0 && (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {rows.map((h) => (
            <li key={h.message_id} className="flex flex-wrap items-center gap-2 p-2 text-sm" data-testid="messages-held-row">
              <Badge variant="outline">Held</Badge>
              <span className="font-medium">{h.sender_name || h.sender_id.slice(0, 8)}</span>
              <span className="text-xs text-muted-foreground">{when(h.created_at)}</span>
              <Button size="sm" variant="outline" className="ml-auto" onClick={() => setOpen(h.conversation_id)}>
                <Eye className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Read and decide
              </Button>
            </li>
          ))}
        </ul>
      )}
      {open && <ChatReader conversationId={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

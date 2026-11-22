/**
 * M31 · Admin → Messages → "Who can message": the DEFAULT RULE (Owner 22 Nov 2026).
 * One rule for every member who has no rule of their own: text / photos / groups / friends only, and the
 * two daily limits. "Save" works at once for those members; "Save and apply to everyone" also replaces
 * every member's own rule (a member's pause date is kept). Every change asks for a reason and is logged.
 */
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import ReasonDialog, { type ReasonRequest } from "./ReasonDialog";
import { adminMessageCall, useRefreshAdminMessages } from "@/hooks/admin/useAdminMessages";

export interface DefaultRule {
  text_ok: boolean; photos_ok: boolean; groups_ok: boolean; friends_only: boolean;
  daily_limit: number; new_daily_limit: number; updated_at: string | null; own_rules: number; paused: number;
}

export const DEFAULT_RULE_KEY = ["admin-messages-default-rule"] as const;

export function useDefaultRule() {
  return useQuery({
    queryKey: DEFAULT_RULE_KEY,
    queryFn: async () => (await adminMessageCall("admin_message_default_get", {})) as DefaultRule,
    staleTime: 20_000,
  });
}

const whole = (s: string) => {
  const n = Number(s);
  return s.trim() !== "" && Number.isInteger(n) && n >= 0 && n <= 100000 ? n : null;
};

export default function DefaultRuleCard() {
  const q = useDefaultRule();
  const qc = useQueryClient();
  const refresh = useRefreshAdminMessages();
  const [draft, setDraft] = useState<{ text: boolean; photos: boolean; groups: boolean; friends: boolean; limit: string; newLimit: string } | null>(null);
  const [request, setRequest] = useState<ReasonRequest | null>(null);

  if (q.isLoading) return <div className="flex justify-center py-6"><Loader2 className="h-5 w-5 animate-spin text-muted-foreground" aria-label="Loading" /></div>;
  if (q.error || !q.data) return <p className="rounded-lg border border-destructive/40 p-3 text-sm text-destructive" role="alert">Could not load the default rule: {(q.error as Error | null)?.message ?? "no answer"}</p>;

  const d = q.data;
  const v = draft ?? { text: d.text_ok, photos: d.photos_ok, groups: d.groups_ok, friends: d.friends_only, limit: String(d.daily_limit), newLimit: String(d.new_daily_limit) };
  const set = (patch: Partial<typeof v>) => setDraft({ ...v, ...patch });
  const limit = whole(v.limit);
  const newLimit = whole(v.newLimit);
  const changed = v.text !== d.text_ok || v.photos !== d.photos_ok || v.groups !== d.groups_ok || v.friends !== d.friends_only
    || limit !== d.daily_limit || newLimit !== d.new_daily_limit;
  const valid = limit !== null && newLimit !== null;

  const summary = [
    v.text ? "text" : null, v.photos ? "photos" : null, v.groups ? "groups" : null,
  ].filter(Boolean).join(", ") || "nothing";

  const ask = (apply: boolean) => {
    if (!valid) return;
    setRequest({
      title: apply ? "Save and apply to everyone?" : "Save the default rule?",
      body: apply
        ? `Every member gets: ${summary}${v.friends ? ", friends only" : ""}; ${limit} messages a day (${newLimit} in the first 7 days). `
          + `${d.own_rules} member${d.own_rules === 1 ? "" : "s"} with their own rules lose them now. Pause dates stay.`
        : `Works at once for every member without their own rules: ${summary}${v.friends ? ", friends only" : ""}; `
          + `${limit} messages a day (${newLimit} in the first 7 days). ${d.own_rules} member${d.own_rules === 1 ? "" : "s"} with their own rules keep them.`,
      button: apply ? "Apply to everyone" : "Save",
      destructive: apply,
      doneText: apply ? "Default rule applied to everyone" : "Default rule saved",
      run: async (reason) => {
        await adminMessageCall("message_admin_set_default", {
          _text_ok: v.text, _photos_ok: v.photos, _groups_ok: v.groups, _friends_only: v.friends,
          _daily_limit: limit, _new_daily_limit: newLimit, _apply: apply, _reason: reason,
        });
        setDraft(null);
        await Promise.all([qc.invalidateQueries({ queryKey: DEFAULT_RULE_KEY }), refresh()]);
      },
    });
  };

  const row = (label: string, hint: string, on: boolean, change: (b: boolean) => void, id: string) => (
    <label className="flex items-center justify-between gap-3 py-2 text-sm" htmlFor={id}>
      <span><span className="font-medium">{label}</span><span className="block text-xs text-muted-foreground">{hint}</span></span>
      <Switch id={id} checked={on} onCheckedChange={change} />
    </label>
  );

  return (
    <section aria-label="Default rule" className="space-y-3 rounded-xl border border-border bg-card p-4" data-testid="messages-default-rule">
      <div>
        <h3 className="text-sm font-semibold">Default rule for all members</h3>
        <p className="text-xs text-muted-foreground">
          Used by every member who has no rule of their own, and by every new member. Changes work at once.
          {d.own_rules > 0 && ` ${d.own_rules} member${d.own_rules === 1 ? " has" : "s have"} their own rules${d.paused > 0 ? ` (${d.paused} paused)` : ""}.`}
        </p>
      </div>
      <div className="divide-y divide-border">
        {row("Text", "Can send text messages", v.text, (b) => set({ text: b }), "default-text")}
        {row("Photos", "Can send photos in chats", v.photos, (b) => set({ photos: b }), "default-photos")}
        {row("Groups", "Can make and join group chats (when Groups is on above)", v.groups, (b) => set({ groups: b }), "default-groups")}
        {row("Friends only", "Can message friends only, nobody else", v.friends, (b) => set({ friends: b }), "default-friends")}
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="space-y-1 text-sm">
          <span className="font-medium">Messages per day</span>
          <Input inputMode="numeric" value={v.limit} onChange={(e) => set({ limit: e.target.value })} aria-invalid={limit === null} data-testid="default-limit" />
          <span className="block text-xs text-muted-foreground">All messages one member can send in 24 hours, to everyone together.</span>
        </label>
        <label className="space-y-1 text-sm">
          <span className="font-medium">Messages per day — new members</span>
          <Input inputMode="numeric" value={v.newLimit} onChange={(e) => set({ newLimit: e.target.value })} aria-invalid={newLimit === null} data-testid="default-new-limit" />
          <span className="block text-xs text-muted-foreground">For the first 7 days after joining.</span>
        </label>
      </div>
      <p className="text-xs text-muted-foreground">Always, for everyone: at most 20 messages a minute and 30 new chats a day.</p>
      {!valid && <p className="text-xs text-destructive">Use whole numbers from 0 to 100000.</p>}
      <div className="flex flex-wrap gap-2">
        <Button onClick={() => ask(false)} disabled={!changed || !valid} data-testid="default-save">Save default</Button>
        <Button variant="destructive" onClick={() => ask(true)} disabled={!valid} data-testid="default-apply">Save and apply to everyone</Button>
        {draft && <Button variant="ghost" onClick={() => setDraft(null)}>Undo changes</Button>}
      </div>
      <ReasonDialog request={request} onClose={() => setRequest(null)} />
    </section>
  );
}

/**
 * PUSH CENTRE (PN3) — write a message, pick who gets it, see the real count
 * and the lock-screen preview, then test, send now or schedule.
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { CalendarClock, Clock, ImagePlus, Loader2, Plus, Save, Search, Send, Smartphone, Trash2, X } from "lucide-react";
import { toast } from "@/hooks/core/use-toast";
import { cn } from "@/lib/utils";
import { compressImageToFiles } from "@/lib/imageCompression";
import { generateImagePath, uploadImage } from "@/lib/imageUpload";
import OptimizedImage from "@/components/OptimizedImage";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { DEFAULT_MEMBER_FILTERS, useAdminMembers } from "@/hooks/admin/useAdminMembers";
import { MemberAvatar, useMemberLabels } from "@/components/admin/users/memberUi";
import {
  audienceLabel, usePushAudience, usePushWrites, type PushAudience, type PushDraft, type SendResult,
} from "@/hooks/admin/usePushCentre";
import { AudiencePanel, PhonePreview } from "./pushUi";

const label = "mb-1 block text-[10px] uppercase tracking-[0.15em] text-muted-foreground";
const card = "rounded-xl border border-border bg-card p-3 sm:p-4 space-y-3";
const QUICK_LINKS = ["/feed", "/competitions", "/dashboard", "/notifications"];

/** ISO → the value a datetime-local input shows (viewer's time). */
export function toLocalInput(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}
const fromLocalInput = (v: string) => (v ? new Date(v).toISOString() : "");
const NewAppTag = () => (
  <span className="ml-1.5 rounded-full border border-primary/30 bg-primary/10 px-1.5 py-px text-[9px] font-semibold uppercase tracking-wide text-primary">new app</span>
);

function MemberPicker({ ids, onChange }: { ids: string[]; onChange: (ids: string[]) => void }) {
  const [q, setQ] = useState("");
  const [debounced, setDebounced] = useState("");
  const [names, setNames] = useState<Record<string, { name: string; avatar: string | null }>>({});
  useEffect(() => { const t = setTimeout(() => setDebounced(q.trim()), 300); return () => clearTimeout(t); }, [q]);
  const { data, isFetching } = useAdminMembers({ ...DEFAULT_MEMBER_FILTERS, query: debounced, pageSize: 8 });
  const results = debounced ? data?.rows ?? [] : [];
  return (
    <div className="space-y-2" data-testid="push-member-picker">
      <div className="relative">
        <Search className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search by name, e-mail or @handle" className="h-9 pl-8 text-xs" />
        {isFetching && <Loader2 className="absolute right-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 animate-spin text-muted-foreground" />}
      </div>
      {results.length > 0 && (
        <ul className="max-h-48 overflow-auto rounded-lg border border-border">
          {results.map((m) => {
            const on = ids.includes(m.id);
            return (
              <li key={m.id}>
                <button type="button" onClick={() => {
                  setNames((n) => ({ ...n, [m.id]: { name: m.full_name || "Member", avatar: m.avatar_url } }));
                  onChange(on ? ids.filter((x) => x !== m.id) : [...ids, m.id].slice(0, 500));
                }} className={cn("flex w-full items-center gap-2 px-2.5 py-1.5 text-left text-xs hover:bg-muted", on && "bg-primary/5")}>
                  <MemberAvatar m={m} size={24} />
                  <span className="min-w-0 flex-1 truncate">{m.full_name || "Member"}</span>
                  <span className={cn("text-[10px]", on ? "text-primary" : "text-muted-foreground")}>{on ? "Added" : "Add"}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {ids.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {ids.map((id) => (
            <span key={id} className="inline-flex items-center gap-1 rounded-full border border-border bg-muted/50 py-0.5 pl-2 pr-1 text-[11px]">
              {names[id]?.name ?? "Member"}
              <button type="button" aria-label="Remove" onClick={() => onChange(ids.filter((x) => x !== id))} className="rounded-full p-0.5 hover:bg-muted"><X className="h-3 w-3" /></button>
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function AudiencePicker({ value, onChange }: { value: PushAudience; onChange: (a: PushAudience) => void }) {
  const labels = useMemberLabels();
  const opts: Array<{ key: string; text: string; pick: () => PushAudience }> = [
    { key: "all", text: "Everyone", pick: () => ({ kind: "all" }) },
    { key: "active7", text: "Active · 7 days", pick: () => ({ kind: "active", days: 7 }) },
    { key: "active30", text: "Active · 30 days", pick: () => ({ kind: "active", days: 30 }) },
    { key: "role", text: "A role", pick: () => ({ kind: "role", role: labels.allRoles.find((r) => r !== "user") ?? "admin" }) },
    { key: "badge", text: "A badge", pick: () => ({ kind: "badge", badge: labels.allBadges[0] ?? "" }) },
    { key: "members", text: "Chosen members", pick: () => ({ kind: "members", ids: [] }) },
  ];
  const current = value.kind === "active" ? `active${value.days}` : value.kind;
  return (
    <div className="space-y-2.5">
      <div className="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Who gets it">
        {opts.map((o) => (
          <button key={o.key} type="button" role="radio" aria-checked={current === o.key} data-testid={`push-audience-${o.key}`}
            onClick={() => onChange(o.pick())}
            className={cn("rounded-full border px-3 py-1.5 text-[11px] transition-colors",
              current === o.key ? "border-primary bg-primary text-primary-foreground" : "border-border hover:border-primary/60")}>
            {o.text}
          </button>
        ))}
      </div>
      {value.kind === "role" && (
        <Select value={value.role} onValueChange={(role) => onChange({ kind: "role", role })}>
          <SelectTrigger className="h-9 w-full text-xs sm:w-64"><SelectValue /></SelectTrigger>
          <SelectContent>{labels.allRoles.filter((r) => r !== "user").map((r) => (
            <SelectItem key={r} value={r} className="text-xs">{labels.role(r).icon} {labels.role(r).label}</SelectItem>
          ))}</SelectContent>
        </Select>
      )}
      {value.kind === "badge" && (
        <Select value={value.badge} onValueChange={(badge) => onChange({ kind: "badge", badge })}>
          <SelectTrigger className="h-9 w-full text-xs sm:w-64"><SelectValue placeholder="Pick a badge" /></SelectTrigger>
          <SelectContent>{labels.allBadges.map((b) => (
            <SelectItem key={b} value={b} className="text-xs">{labels.badge(b).icon} {labels.badge(b).label}</SelectItem>
          ))}</SelectContent>
        </Select>
      )}
      {value.kind === "members" && <MemberPicker ids={value.ids} onChange={(ids) => onChange({ kind: "members", ids })} />}
    </div>
  );
}

function PictureButton({ onUrl, busy, setBusy, text }: { onUrl: (u: string) => void; busy: boolean; setBusy: (b: boolean) => void; text: string }) {
  const ref = useRef<HTMLInputElement>(null);
  const pick = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (e.target) e.target.value = "";
    if (!file) return;
    if (!file.type.startsWith("image/")) { toast({ title: "Please choose a picture (jpg / png / webp)", variant: "destructive" }); return; }
    setBusy(true);
    try {
      const { webpFile } = await compressImageToFiles(file, "push-broadcast", { maxDimension: 1200 });
      const { url } = await uploadImage({
        bucket: "journal-images", file: webpFile, path: generateImagePath({ type: "ad", ext: "webp" }), type: "ad", fileName: "push-broadcast.webp",
      });
      onUrl(url);
    } catch (err) {
      toast({ title: "Upload failed", description: (err as Error)?.message, variant: "destructive" });
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <input ref={ref} type="file" accept="image/*" className="hidden" onChange={pick} />
      <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => ref.current?.click()} className="h-8 text-[11px]">
        {busy ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <ImagePlus className="mr-1.5 h-3.5 w-3.5" />}{text}
      </Button>
    </>
  );
}

interface Props {
  draft: PushDraft;
  setDraft: (d: PushDraft) => void;
  onDone: (where: "history" | "scheduled" | "drafts" | "templates") => void;
}

export default function PushComposer({ draft, setDraft, onDone }: Props) {
  const set = <K extends keyof PushDraft>(k: K, v: PushDraft[K]) => setDraft({ ...draft, [k]: v });
  const [debouncedAudience, setDebouncedAudience] = useState(draft.audience);
  useEffect(() => { const t = setTimeout(() => setDebouncedAudience(draft.audience), 250); return () => clearTimeout(t); }, [draft.audience]);
  const { data: count, isFetching } = usePushAudience(debouncedAudience);
  const writes = usePushWrites();
  const [when, setWhen] = useState<"now" | "later">("now");
  const [at, setAt] = useState("");
  const [busy, setBusy] = useState<null | "save" | "template" | "test" | "send">(null);
  const [uploading, setUploading] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [typed, setTyped] = useState("");
  const [lastTest, setLastTest] = useState<SendResult | null>(null);

  const titleOk = draft.title.trim().length > 0;
  const audienceOk = draft.audience.kind !== "members" || draft.audience.ids.length > 0;
  const atOk = when === "now" || (!!at && Date.parse(at) > Date.now());
  const canSend = titleOk && audienceOk && atOk && !busy && !uploading;
  const audienceText = useMemo(() => audienceLabel(draft.audience), [draft.audience]);

  const run = async (kind: NonNullable<typeof busy>) => {
    setBusy(kind);
    try {
      if (kind === "save" || kind === "template") {
        const r = await writes.save({ ...draft, kind: kind === "template" ? "template" : draft.kind, id: kind === "template" && draft.kind !== "template" ? null : draft.id });
        if (r.error) { toast({ title: "Not saved", description: r.error, variant: "destructive" }); return; }
        toast({ title: kind === "template" ? "Saved as a template ✅" : "Draft saved ✅" });
        if (kind === "save") setDraft({ ...draft, id: r.id });
        onDone(kind === "template" ? "templates" : "drafts");
      } else if (kind === "test") {
        const { id, result } = await writes.test(draft);
        if (id) setDraft({ ...draft, id });
        setLastTest(result);
        if (result.error) toast({ title: "Test not sent", description: result.error, variant: "destructive" });
        else if (!result.devices) toast({ title: "No phone on your account", description: result.note });
        else toast({ title: `Test sent to your ${result.sent} phone${result.sent === 1 ? "" : "s"} ✅` });
      } else {
        const { result } = await writes.schedule(draft, when === "now" ? null : at);
        if (result.error) { toast({ title: when === "now" ? "Send failed" : "Not scheduled", description: result.error, variant: "destructive" }); return; }
        toast({
          title: when === "now"
            ? `Sent to ${result.sent ?? 0} phone${result.sent === 1 ? "" : "s"} ✅`
            : `Scheduled for ${new Date(at).toLocaleString(undefined, { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" })} ✅`,
        });
        onDone(when === "now" ? "history" : "scheduled");
      }
    } finally {
      setBusy(null);
    }
  };

  const setCountdown = (hours: number) => set("countdown_until", new Date(Date.now() + hours * 3600_000).toISOString());

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]" data-testid="push-composer">
      <div className="space-y-4">
        <section className={card}>
          <div>
            <label className={label} htmlFor="push-title">Title (required)</label>
            <Input id="push-title" value={draft.title} maxLength={80} onChange={(e) => set("title", e.target.value)} placeholder="e.g. Monsoon Moods closes tonight" className="text-sm" />
          </div>
          <div>
            <label className={label} htmlFor="push-body">Message</label>
            <Textarea id="push-body" value={draft.body} maxLength={240} onChange={(e) => set("body", e.target.value)} placeholder="One or two lines people read on the lock screen." className="min-h-[72px] text-sm" />
            <p className="mt-0.5 text-right text-[10px] text-muted-foreground">{draft.body.length}/240</p>
          </div>
          <div>
            <label className={label} htmlFor="push-link">Opens when tapped</label>
            <Input id="push-link" value={draft.link} onChange={(e) => set("link", e.target.value)} placeholder="/competitions" className="text-sm" />
            <div className="mt-1.5 flex flex-wrap gap-1">
              {QUICK_LINKS.map((l) => (
                <button key={l} type="button" onClick={() => set("link", l)} className={cn("rounded border px-2 py-0.5 text-[10px]", draft.link === l ? "border-primary text-primary" : "border-border text-muted-foreground hover:border-primary/60")}>{l}</button>
              ))}
            </div>
          </div>
        </section>

        <section className={card}>
          <div>
            <p className={label}>Picture</p>
            <div className="flex flex-wrap items-center gap-2">
              {draft.image_url && (
                <span className="relative">
                  <OptimizedImage src={draft.image_url} alt="" className="h-14 w-14 rounded object-cover" />
                  <button type="button" aria-label="Remove picture" onClick={() => set("image_url", "")} className="absolute -right-1.5 -top-1.5 rounded-full bg-background p-0.5 shadow"><X className="h-3 w-3" /></button>
                </span>
              )}
              <PictureButton busy={uploading} setBusy={setUploading} onUrl={(u) => set("image_url", u)} text={draft.image_url ? "Change" : "Add a picture"} />
            </div>
          </div>
          <div>
            <p className={label}>Picture slides <NewAppTag /></p>
            <div className="flex flex-wrap items-center gap-2">
              {draft.images.map((u, i) => (
                <span key={`${u}-${i}`} className="relative">
                  <OptimizedImage src={u} alt="" className="h-14 w-20 rounded object-cover" />
                  <button type="button" aria-label="Remove slide" onClick={() => set("images", draft.images.filter((_, k) => k !== i))} className="absolute -right-1.5 -top-1.5 rounded-full bg-background p-0.5 shadow"><X className="h-3 w-3" /></button>
                </span>
              ))}
              {draft.images.length < 5 && <PictureButton busy={uploading} setBusy={setUploading} onUrl={(u) => set("images", [...draft.images, u])} text={`Add a slide (${draft.images.length}/5)`} />}
            </div>
          </div>
          <div>
            <p className={label}>Live countdown <NewAppTag /></p>
            <div className="flex flex-wrap items-center gap-2">
              <Input type="datetime-local" value={toLocalInput(draft.countdown_until)} onChange={(e) => set("countdown_until", fromLocalInput(e.target.value))} className="h-9 w-auto text-xs" aria-label="Countdown ends" />
              {[["+1 hour", 1], ["+1 day", 24], ["+3 days", 72]].map(([t, h]) => (
                <button key={t} type="button" onClick={() => setCountdown(h as number)} className="rounded border border-border px-2 py-1 text-[10px] hover:border-primary/60">{t}</button>
              ))}
              {draft.countdown_until && <button type="button" onClick={() => set("countdown_until", "")} className="text-[10px] text-muted-foreground underline">Clear</button>}
            </div>
            <p className="mt-1 text-[10px] text-muted-foreground">Ticks on the lock screen; older app phones see a fixed "Ends …" line.</p>
          </div>
          <div>
            <p className={label}>Buttons <NewAppTag /></p>
            <div className="space-y-2">
              {draft.actions.map((a, i) => (
                <div key={i} className="flex gap-2">
                  <Input value={a.label} maxLength={20} placeholder="Enter now" aria-label="Button text"
                    onChange={(e) => set("actions", draft.actions.map((x, k) => (k === i ? { ...x, label: e.target.value } : x)))} className="h-9 w-32 text-xs" />
                  <Input value={a.link} placeholder="/competitions/…" aria-label="Button link"
                    onChange={(e) => set("actions", draft.actions.map((x, k) => (k === i ? { ...x, link: e.target.value } : x)))} className="h-9 flex-1 text-xs" />
                  <button type="button" aria-label="Remove button" onClick={() => set("actions", draft.actions.filter((_, k) => k !== i))} className="px-1 text-muted-foreground hover:text-destructive"><Trash2 className="h-3.5 w-3.5" /></button>
                </div>
              ))}
              {draft.actions.length < 2 && (
                <button type="button" onClick={() => set("actions", [...draft.actions, { label: "", link: draft.link || "/" }])} className="inline-flex items-center gap-1 text-[11px] text-primary"><Plus className="h-3.5 w-3.5" /> Add a button</button>
              )}
            </div>
          </div>
        </section>

        <section className={card}>
          <p className={label}>Who gets it</p>
          <AudiencePicker value={draft.audience} onChange={(a) => set("audience", a)} />
        </section>

        <section className={card}>
          <p className={label}>When</p>
          <div className="flex flex-wrap items-center gap-2">
            {(["now", "later"] as const).map((w) => (
              <button key={w} type="button" onClick={() => setWhen(w)} data-testid={`push-when-${w}`}
                className={cn("inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-[11px]", when === w ? "border-primary bg-primary text-primary-foreground" : "border-border")}>
                {w === "now" ? <Send className="h-3.5 w-3.5" /> : <CalendarClock className="h-3.5 w-3.5" />}{w === "now" ? "Send now" : "Schedule"}
              </button>
            ))}
            {when === "later" && (
              <Input type="datetime-local" value={toLocalInput(at)} onChange={(e) => setAt(fromLocalInput(e.target.value))} className="h-9 w-auto text-xs" aria-label="Send at" />
            )}
          </div>
          {when === "later" && count && !count.scheduling_on && (
            <p className="text-[11px] text-destructive">Scheduling is switched off on this site — use Send now.</p>
          )}
        </section>

        <div className="sticky bottom-0 z-10 -mx-1 flex flex-wrap items-center gap-2 border-t border-border bg-background/95 px-1 py-3 backdrop-blur">
          <Button type="button" variant="outline" size="sm" disabled={!titleOk || !!busy} onClick={() => run("save")} className="h-9 text-[11px]">
            {busy === "save" ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Save className="mr-1.5 h-3.5 w-3.5" />}Save draft
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={!titleOk || !!busy} onClick={() => run("template")} className="h-9 text-[11px]">
            {busy === "template" ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Save className="mr-1.5 h-3.5 w-3.5" />}Save as template
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={!titleOk || !!busy || uploading} onClick={() => run("test")} className="h-9 text-[11px]" data-testid="push-test">
            {busy === "test" ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Smartphone className="mr-1.5 h-3.5 w-3.5" />}Test on my phone
          </Button>
          <Button type="button" size="sm" disabled={!canSend || (when === "later" && count?.scheduling_on === false)}
            onClick={() => { setTyped(""); setConfirm(true); }} className="ml-auto h-9 text-[11px] uppercase tracking-[0.12em]" data-testid="push-send">
            {busy === "send" ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : when === "now" ? <Send className="mr-1.5 h-3.5 w-3.5" /> : <Clock className="mr-1.5 h-3.5 w-3.5" />}
            {when === "now" ? `Send to ${count?.reachable_members ?? "…"}` : "Schedule"}
          </Button>
          {lastTest && !lastTest.error && (
            <p className="w-full text-[10px] text-muted-foreground">Last test: {lastTest.devices ? `${lastTest.sent} of ${lastTest.devices} of your phones` : lastTest.note}</p>
          )}
        </div>
      </div>

      <aside className="space-y-4 lg:sticky lg:top-4 lg:self-start">
        <PhonePreview title={draft.title} body={draft.body} image={draft.image_url} images={draft.images}
          countdownUntil={draft.countdown_until} actions={draft.actions} />
        <AudiencePanel count={count} loading={isFetching} />
      </aside>

      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{when === "now" ? "Send this now?" : "Schedule this message?"}</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2 text-sm">
                <p><strong>{draft.title}</strong> · {audienceText}</p>
                <p>Reaches <strong>{count?.reachable_members ?? 0}</strong> members on <strong>{count?.devices ?? 0}</strong> phones.
                  {when === "now" ? " Once a phone buzzes it cannot be taken back." : " You can cancel it until it goes."}</p>
                {when === "now" && (
                  <Input autoFocus value={typed} onChange={(e) => setTyped(e.target.value)} placeholder="Type SEND to confirm" aria-label="Type SEND to confirm" />
                )}
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Back</AlertDialogCancel>
            <AlertDialogAction disabled={when === "now" && typed.trim().toUpperCase() !== "SEND"}
              onClick={() => { setConfirm(false); void run("send"); }}>
              {when === "now" ? "Send now" : "Schedule"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

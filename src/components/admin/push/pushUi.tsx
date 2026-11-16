/**
 * PUSH CENTRE (PN3) — small shared pieces: status chips, the live countdown,
 * the phone preview (new app vs older app) and the honest audience panel.
 */
import { useEffect, useState } from "react";
import { Bell, ChevronLeft, ChevronRight, Clock, Smartphone } from "lucide-react";
import OptimizedImage from "@/components/OptimizedImage";
import { cn } from "@/lib/utils";
import type { PushAction, PushAudienceCount, PushStatus } from "@/hooks/admin/usePushCentre";

export const PUSH_STATUS: Record<PushStatus | "stuck", { label: string; cls: string }> = {
  draft: { label: "Draft", cls: "bg-muted text-muted-foreground border-border" },
  scheduled: { label: "Scheduled", cls: "bg-sky-500/10 text-sky-600 border-sky-500/30" },
  sending: { label: "Sending…", cls: "bg-amber-500/10 text-amber-600 border-amber-500/30" },
  sent: { label: "Sent", cls: "bg-emerald-500/10 text-emerald-600 border-emerald-500/30" },
  failed: { label: "Failed", cls: "bg-destructive/10 text-destructive border-destructive/30" },
  cancelled: { label: "Cancelled", cls: "bg-muted text-muted-foreground border-border line-through" },
  stuck: { label: "Interrupted", cls: "bg-destructive/10 text-destructive border-destructive/30" },
};

export function PushStatusChip({ status, stuck }: { status: PushStatus; stuck?: boolean }) {
  const m = PUSH_STATUS[stuck ? "stuck" : status];
  return <span className={cn("inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-medium", m.cls)}>{m.label}</span>;
}

/** "16 Nov, 6:05 pm" in the viewer's time. */
export function fmtWhen(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
}

/** Ticks every second; null when there is no end or it has passed. */
export function useCountdown(iso: string | null | undefined): string | null {
  const [now, setNow] = useState(() => Date.now());
  const end = iso ? Date.parse(iso) : NaN;
  const live = Number.isFinite(end) && end > now;
  useEffect(() => {
    if (!live) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [live]);
  if (!live) return null;
  const s = Math.floor((end - now) / 1000);
  const d = Math.floor(s / 86400);
  const hms = [Math.floor((s % 86400) / 3600), Math.floor((s % 3600) / 60), s % 60]
    .map((n) => String(n).padStart(2, "0")).join(":");
  return d > 0 ? `${d}d ${hms}` : hms;
}

function endsText(iso: string): string {
  const d = new Date(iso);
  return `Ends ${d.toLocaleString("en-IN", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit", hour12: true })}`;
}

interface PreviewProps {
  title: string;
  body: string;
  image: string;
  images: string[];
  countdownUntil: string;
  actions: PushAction[];
}

function Carousel({ images }: { images: string[] }) {
  const [i, setI] = useState(0);
  useEffect(() => {
    if (images.length < 2) return;
    const t = setInterval(() => setI((x) => (x + 1) % images.length), 2500);
    return () => clearInterval(t);
  }, [images.length]);
  const at = Math.min(i, images.length - 1);
  return (
    <div className="relative mt-2 overflow-hidden rounded-lg bg-muted">
      <OptimizedImage src={images[at]} alt="" className="aspect-[2/1] w-full object-cover" />
      {images.length > 1 && (
        <>
          <button type="button" aria-label="Previous picture" onClick={() => setI((at - 1 + images.length) % images.length)}
            className="absolute left-1 top-1/2 -translate-y-1/2 rounded-full bg-black/40 p-0.5 text-white"><ChevronLeft className="h-3.5 w-3.5" /></button>
          <button type="button" aria-label="Next picture" onClick={() => setI((at + 1) % images.length)}
            className="absolute right-1 top-1/2 -translate-y-1/2 rounded-full bg-black/40 p-0.5 text-white"><ChevronRight className="h-3.5 w-3.5" /></button>
          <div className="absolute bottom-1.5 left-1/2 flex -translate-x-1/2 gap-1">
            {images.map((_, k) => <span key={k} className={cn("h-1.5 w-1.5 rounded-full", k === at ? "bg-white" : "bg-white/50")} />)}
          </div>
        </>
      )}
    </div>
  );
}

/** What a member's lock screen shows — the new app (live countdown, buttons, carousel) and the older app. */
export function PhonePreview(p: PreviewProps) {
  const left = useCountdown(p.countdownUntil);
  const pictures = p.images.length ? p.images : p.image ? [p.image] : [];
  const actions = p.actions.filter((a) => a.label.trim());
  return (
    <div className="space-y-3" data-testid="push-preview">
      <div className="rounded-[28px] border border-border bg-gradient-to-b from-zinc-800 to-zinc-900 p-3 shadow-inner">
        <div className="mb-2 flex items-center justify-between px-2 text-[10px] text-white/70">
          <span>18:05</span><span className="flex items-center gap-1"><Smartphone className="h-3 w-3" /> New app</span>
        </div>
        <div className="rounded-2xl bg-white/95 p-3 text-zinc-900 shadow dark:bg-zinc-100">
          <div className="flex items-center gap-1.5 text-[10px] text-zinc-500">
            <Bell className="h-3 w-3 text-primary" />
            <span className="font-medium text-zinc-600">50mm Retina World</span>
            <span>· now</span>
            {left && (
              <span className="ml-auto inline-flex items-center gap-1 rounded-full bg-primary/10 px-1.5 py-0.5 font-mono text-[10px] font-semibold text-primary" data-testid="push-preview-countdown">
                <Clock className="h-3 w-3" /> {left}
              </span>
            )}
          </div>
          <p className="mt-1 truncate text-[13px] font-semibold">{p.title || "Title goes here"}</p>
          <p className="line-clamp-3 whitespace-pre-line text-[12px] text-zinc-600">{p.body || "Your message will appear here."}</p>
          {pictures.length > 0 && <Carousel images={pictures} />}
          {actions.length > 0 && (
            <div className="mt-2 flex gap-4 border-t border-zinc-200 pt-2">
              {actions.map((a, k) => (
                <span key={k} className="text-[11px] font-semibold uppercase tracking-wide text-primary">{a.label}</span>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="rounded-xl border border-dashed border-border p-2.5">
        <p className="mb-1.5 text-[10px] uppercase tracking-[0.12em] text-muted-foreground">Phones on the older app see</p>
        <div className="flex gap-2.5">
          {p.image
            ? <OptimizedImage src={p.image} alt="" className="h-10 w-10 shrink-0 rounded object-cover" />
            : <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded bg-muted"><Bell className="h-4 w-4 text-muted-foreground" /></div>}
          <div className="min-w-0">
            <p className="truncate text-xs font-semibold">{p.title || "Title goes here"}</p>
            <p className="line-clamp-2 whitespace-pre-line text-[11px] text-muted-foreground">
              {[p.body, p.countdownUntil && Date.parse(p.countdownUntil) > Date.now() ? endsText(p.countdownUntil) : ""].filter(Boolean).join("\n") || "Your message will appear here."}
            </p>
          </div>
        </div>
        {(actions.length > 0 || p.images.length > 1 || left) && (
          <p className="mt-1.5 text-[10px] text-muted-foreground">No live timer, buttons or picture slides until they update the app.</p>
        )}
      </div>
    </div>
  );
}

const ROWS: Array<{ key: keyof PushAudienceCount; label: string; hint: string; cls: string }> = [
  { key: "reachable_members", label: "Will get it", hint: "App installed, signed in, notifications allowed", cls: "bg-emerald-500" },
  { key: "said_no", label: "Said No to notifications", hint: "The app asked and they tapped Don't allow", cls: "bg-amber-500" },
  { key: "app_recent_no_phone", label: "Use the app, no phone registered", hint: "Seen in the app in the last 30 days — said No on an older app, or signed out", cls: "bg-orange-400" },
  { key: "app_old_no_phone", label: "Left the app", hint: "Last seen in the app over 30 days ago — most likely deleted it", cls: "bg-zinc-400" },
  { key: "website_only", label: "Website only", hint: "Never used the app — a push cannot reach a browser", cls: "bg-sky-400" },
  { key: "held", label: "Held back", hint: "Banned, suspended or asked to delete — never sent", cls: "bg-destructive" },
];

/** The honest count: who receives, and why every other member does not. */
export function AudiencePanel({ count, loading }: { count: PushAudienceCount | null | undefined; loading?: boolean }) {
  const total = count ? count.matched : 0;
  return (
    <div className={cn("rounded-xl border border-border bg-card p-3", loading && "opacity-70")} data-testid="push-audience">
      <div className="flex items-baseline justify-between gap-2">
        <p className="text-sm font-semibold">
          {count ? <>Reaches <span className="text-lg text-emerald-600">{count.reachable_members}</span> of {total} members</> : "Counting…"}
        </p>
        {count && <p className="text-[11px] text-muted-foreground">{count.devices} phone{count.devices === 1 ? "" : "s"}</p>}
      </div>
      {count && total > 0 && (
        <div className="mt-2 flex h-2 overflow-hidden rounded-full bg-muted">
          {ROWS.map((r) => {
            const n = count[r.key] as number;
            return n > 0 ? <div key={r.key} className={r.cls} style={{ width: `${(n / total) * 100}%` }} title={`${r.label}: ${n}`} /> : null;
          })}
        </div>
      )}
      {count && (
        <ul className="mt-2.5 space-y-1.5">
          {ROWS.map((r) => (
            <li key={r.key} className="flex items-start gap-2 text-[11px]" title={r.hint}>
              <span className={cn("mt-1 h-2 w-2 shrink-0 rounded-full", r.cls)} />
              <span className="min-w-0 flex-1">
                <span className="font-medium text-foreground">{r.label}</span>
                <span className="block text-[10px] leading-tight text-muted-foreground">{r.hint}</span>
              </span>
              <span className="font-mono text-xs tabular-nums">{count[r.key] as number}</span>
            </li>
          ))}
        </ul>
      )}
      {count && count.devices > 0 && (
        <p className="mt-2 border-t border-border pt-2 text-[10px] text-muted-foreground">
          {count.rich_devices} of {count.devices} phones have the new app (live timer, buttons, slides). The rest get the plain version.
        </p>
      )}
    </div>
  );
}

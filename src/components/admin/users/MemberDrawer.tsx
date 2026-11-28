/**
 * Admin → Users: one member, opened from the table. Everything about them on
 * one panel — status and why, roles, badges, name/bio, account actions and the
 * account history (A4 log). Actions call the same writers as the table.
 */
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ExternalLink, Ban, ShieldCheck, ShieldAlert, UserCheck, Trash2, CheckCircle2, PauseCircle, Loader2, Smartphone, Globe } from "lucide-react";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { memberPath } from "@/lib/urlHelpers";
import { formatLastSeen } from "@/hooks/core/useLastActive";
import { toast } from "@/hooks/core/use-toast";
import type { AdminMember } from "@/hooks/admin/useAdminMembers";
import type { PendingAccountAction } from "@/components/admin/AccountActionDialog";
import { AccountHistoryList } from "@/components/admin/AccountActionDialog";
import { MemberAvatar, StatusChip, STATUS_META, appLabel, fmtDate, istDateTime, platformsUsed, statusDetail, type MemberLabels } from "./memberUi";

export interface MemberActions {
  setRole: (m: AdminMember, role: string, on: boolean) => void;
  setBadge: (m: AdminMember, badge: string, on: boolean) => void;
  saveProfile: (m: AdminMember, name: string, bio: string) => Promise<string | null>;
  suspend: (ms: AdminMember[]) => void;
  lift: (m: AdminMember) => void;
  account: (kind: PendingAccountAction["kind"], ms: AdminMember[]) => void;
}

const Section = ({ title, children }: { title: string; children: React.ReactNode }) => (
  <section className="space-y-2 border-t border-border pt-4">
    <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{title}</h3>
    {children}
  </section>
);

export function MemberDrawer({
  member, online, labels, actions, onClose,
}: { member: AdminMember | null; online: boolean; labels: MemberLabels; actions: MemberActions; onClose: () => void }) {
  const [name, setName] = useState("");
  const [bio, setBio] = useState("");
  const [saving, setSaving] = useState(false);
  useEffect(() => { setName(member?.full_name ?? ""); setBio(member?.bio ?? ""); }, [member?.id, member?.full_name, member?.bio]);

  const m = member;
  const href = m ? memberPath(m.custom_url) : null;
  const detail = m ? statusDetail(m) : null;
  const reason = m ? (m.status === "suspended" || m.status === "banned" ? m.suspension_reason : m.review_reason) : null;
  const asked = m?.status === "deletion_requested";
  const reviewed = m?.status === "under_review" || asked;

  return (
    <Sheet open={!!m} onOpenChange={(o) => { if (!o) onClose(); }}>
      <SheetContent side="right" className="w-full overflow-y-auto sm:max-w-md" data-testid="member-drawer">
        {m && (
          <div className="space-y-4">
            <SheetHeader className="space-y-3 text-left">
              <div className="flex items-start gap-3">
                <MemberAvatar m={m} size={56} />
                <div className="min-w-0 flex-1 space-y-1">
                  <SheetTitle className="truncate text-lg">{m.full_name || "No name"}</SheetTitle>
                  <SheetDescription className="truncate">{m.email ?? "—"}</SheetDescription>
                  <div className="flex flex-wrap items-center gap-2">
                    <StatusChip status={m.status} />
                    {href && (
                      <a href={href} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-xs text-primary hover:underline">
                        @{m.custom_url} <ExternalLink className="h-3 w-3" />
                      </a>
                    )}
                  </div>
                </div>
              </div>
            </SheetHeader>

            {m.status !== "active" && (
              <div className={cn("rounded-lg border p-3 text-sm", STATUS_META[m.status].chip)} data-testid="member-status-callout">
                <p className="font-medium">{STATUS_META[m.status].label}{detail ? ` · ${detail}` : ""}</p>
                {reason && <p className="mt-0.5 opacity-90">“{reason}”</p>}
                {reviewed && (
                  <Link to="/admin/account_reviews" className="mt-1 inline-block text-xs underline">Open in Account Review</Link>
                )}
              </div>
            )}

            <dl className="grid grid-cols-2 gap-3 text-sm">
              <div><dt className="text-xs text-muted-foreground">Joined</dt><dd>{istDateTime(m.created_at) ?? fmtDate(m.created_at)}</dd></div>
              <div>
                <dt className="text-xs text-muted-foreground">Last active</dt>
                <dd className={online ? "font-medium text-emerald-600" : undefined} title={formatLastSeen(m.last_active_at) || undefined}>{online ? "Active now" : istDateTime(m.last_active_at) || "Never recorded"}</dd>
              </div>
              <div><dt className="text-xs text-muted-foreground">Last login</dt><dd>{istDateTime(m.last_sign_in_at) || "Not recorded"}</dd></div>
              <div><dt className="text-xs text-muted-foreground">App version</dt><dd>{m.app_version ? appLabel(m).replace(/^App /, "") : "Not reported"}</dd></div>
              <div>
                <dt className="text-xs text-muted-foreground">Signs in from</dt>
                <dd className="flex flex-col gap-0.5">
                  {platformsUsed(m).length === 0 && <span className="text-muted-foreground">Unknown</span>}
                  {platformsUsed(m).map((u) => (
                    <span key={u.kind} className="flex items-center gap-1">
                      {u.kind === "app" ? <Smartphone className="h-3.5 w-3.5" /> : <Globe className="h-3.5 w-3.5" />}
                      {u.kind === "app" ? "App" : "Website"}
                      {platformsUsed(m).length > 1 && u.latest && <span className="text-xs text-muted-foreground">(latest)</span>}
                    </span>
                  ))}
                </dd>
              </div>
              <div><dt className="text-xs text-muted-foreground">Member ID</dt><dd className="truncate font-mono text-xs" title={m.id}>{m.id.slice(0, 8)}…</dd></div>
            </dl>

            <Section title="Roles">
              <div className="flex flex-wrap gap-1.5" data-testid="drawer-roles">
                {labels.allRoles.map((r) => {
                  const has = m.roles.includes(r);
                  const l = labels.role(r);
                  return (
                    <button
                      key={r}
                      type="button"
                      disabled={r === "user" && has}
                      aria-pressed={has}
                      onClick={() => actions.setRole(m, r, !has)}
                      className={cn("inline-flex min-h-8 items-center gap-1 rounded-md border px-2 text-xs transition-colors disabled:opacity-60",
                        has ? l.cls : "border-dashed border-border text-muted-foreground hover:border-primary hover:text-foreground")}
                    >
                      {l.icon && <span aria-hidden>{l.icon}</span>}{l.label}{has ? " ✓" : " +"}
                    </button>
                  );
                })}
              </div>
            </Section>

            {labels.allBadges.length > 0 && (
              <Section title="Badges">
                <div className="flex flex-wrap gap-1.5">
                  {labels.allBadges.map((b) => {
                    const has = m.badges.includes(b);
                    const l = labels.badge(b);
                    return (
                      <button key={b} type="button" aria-pressed={has} onClick={() => actions.setBadge(m, b, !has)}
                        className={cn("inline-flex min-h-8 items-center gap-1 rounded-md border px-2 text-xs transition-colors",
                          has ? l.cls : "border-dashed border-border text-muted-foreground hover:border-primary hover:text-foreground")}>
                        <span aria-hidden>{l.icon}</span>{l.label}{has ? " ✓" : " +"}
                      </button>
                    );
                  })}
                </div>
              </Section>
            )}

            <Section title="Profile">
              <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Full name" aria-label="Full name" />
              <Textarea value={bio} onChange={(e) => setBio(e.target.value)} placeholder="Bio" aria-label="Bio" rows={2} />
              <Button size="sm" variant="outline" disabled={saving || (name === (m.full_name ?? "") && bio === (m.bio ?? ""))}
                onClick={async () => {
                  setSaving(true);
                  const err = await actions.saveProfile(m, name, bio);
                  setSaving(false);
                  toast(err ? { title: "Not saved", description: err, variant: "destructive" } : { title: "Profile saved" });
                }}>
                {saving && <Loader2 className="mr-1 h-4 w-4 animate-spin" />}Save
              </Button>
            </Section>

            <Section title="Account">
              <div className="flex flex-wrap gap-2">
                {m.status === "suspended" || m.status === "banned" ? (
                  <Button size="sm" variant="outline" onClick={() => actions.lift(m)}><ShieldCheck className="mr-1 h-4 w-4" />Lift suspension</Button>
                ) : (
                  <Button size="sm" variant="outline" onClick={() => actions.suspend([m])}><Ban className="mr-1 h-4 w-4" />Suspend…</Button>
                )}
                {reviewed ? (
                  <Button size="sm" variant="outline" onClick={() => actions.account("active", [m])}><UserCheck className="mr-1 h-4 w-4" />Make active</Button>
                ) : (
                  <Button size="sm" variant="outline" onClick={() => actions.account("under_review", [m])}><ShieldAlert className="mr-1 h-4 w-4" />Put under review…</Button>
                )}
                {asked && (
                  <>
                    <Button size="sm" variant="destructive" onClick={() => actions.account("approve", [m])}><CheckCircle2 className="mr-1 h-4 w-4" />Approve deletion</Button>
                    <Button size="sm" variant="outline" onClick={() => actions.account("hold", [m])}><PauseCircle className="mr-1 h-4 w-4" />Hold</Button>
                  </>
                )}
                {!asked && (
                  <Button size="sm" variant="outline" className="text-destructive" onClick={() => actions.account("delete", [m])}><Trash2 className="mr-1 h-4 w-4" />Delete member…</Button>
                )}
              </div>
            </Section>

            <Section title="Account history">
              <AccountHistoryList userId={m.id} />
            </Section>
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}

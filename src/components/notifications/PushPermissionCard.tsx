/**
 * PUSH CENTRE PN4 · item 9 — "Turn on notifications", for members who said No.
 *
 * ONE card, used on /notifications and /settings/notifications. Shown only
 * inside the installed app (from 1.2.50) when the phone itself says this
 * app's notifications are off — pushStatus() reads the phone's own switch, so
 * a member who blocked them in Android settings is caught too. On the web, and
 * in older builds, pushStatus() answers null and nothing renders.
 *
 * "Turn on" opens this app's notification settings on the phone (Android never
 * shows its permission prompt a second time). When the member comes back, the
 * phone is asked again; if they switched notifications on, push setup runs
 * again (retryPushSetup) so this device registers and starts receiving, and
 * the card goes away by itself.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { BellOff } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/I18nContext";
import { openPushSettings, pushStatus } from "@/lib/native/pushCentre";

type CapApp = { addListener?: (ev: "resume", cb: () => void) => Promise<{ remove: () => void }> | { remove: () => void } };
const capApp = (): CapApp | undefined =>
  (window as unknown as { Capacitor?: { Plugins?: { App?: CapApp } } }).Capacitor?.Plugins?.App;

export default function PushPermissionCard({ className = "" }: { className?: string }) {
  const t = useT();
  const [off, setOff] = useState(false);
  const wasOff = useRef(false);

  const check = useCallback(async () => {
    const s = await pushStatus();
    const nowOff = s !== null && !s.enabled; // null: web, or a build that cannot tell
    // switched on in the phone's settings while we were away → register this device now
    if (wasOff.current && s?.enabled) {
      void import("@/lib/native/push").then((m) => m.retryPushSetup()).catch(() => {});
    }
    wasOff.current = nowOff;
    setOff(nowOff);
  }, []);

  useEffect(() => {
    void check();
    const onVisible = () => { if (document.visibilityState === "visible") void check(); };
    document.addEventListener("visibilitychange", onVisible);
    let sub: { remove: () => void } | undefined;
    let gone = false;
    void Promise.resolve(capApp()?.addListener?.("resume", () => { void check(); }))
      .then((s) => { if (gone) s?.remove(); else sub = s; })
      .catch(() => {});
    return () => {
      gone = true;
      document.removeEventListener("visibilitychange", onVisible);
      sub?.remove();
    };
  }, [check]);

  if (!off) return null;

  return (
    <div
      role="region"
      aria-label={t("push.off.title", "Notifications are off")}
      className={`flex items-start gap-3 rounded-xl border border-border bg-muted/40 p-3 ${className}`}
      data-testid="push-permission-card"
    >
      <div className="mt-0.5 rounded-full bg-primary/10 p-2 text-primary">
        <BellOff className="h-4 w-4" aria-hidden="true" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold text-foreground">{t("push.off.title", "Notifications are off")}</p>
        <p className="mt-0.5 text-xs text-muted-foreground">
          {t("push.off.body", "Turn them on to hear about comments, likes and competitions.")}
        </p>
      </div>
      <Button size="sm" className="shrink-0 self-center" onClick={() => { void openPushSettings(); }}>
        {t("push.off.button", "Turn on")}
      </Button>
    </div>
  );
}

/**
 * N5b · Admin → App health → "Speed per screen" (Owner 23 Nov: "build like Meta").
 * Reads admin_screen_speed (20261123_4900): per day × screen × app, how long each main screen
 * took to show — typical (half of the opens were faster) and slowest 1 in 20. Red when past the
 * alarm line (the same lines n5_screen_speed_alarms e-mails on: typical 2.5 s, slowest 6 s).
 */
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";

interface Row { day: string; screen: string; cold: boolean; platform: string; n: number; p50: number; p75: number; p95: number }

export const SCREEN_NAMES: Record<string, string> = {
  feed: "Feed", messages: "Messages", chat: "A chat", profile: "A profile",
  notifications: "Notifications", competitions: "Competitions",
};
const APP: Record<string, string> = { web: "Website", android: "Android", ios: "iPhone" };
export const LIMIT_P50 = 2500;
export const LIMIT_P95 = 6000;

const sec = (ms: number) => `${(ms / 1000).toFixed(ms < 10_000 ? 2 : 1)} s`;

/** The newest day per screen × app × (cold or not), plus the day before for the trend. */
export function latestPerScreen(rows: Row[]): Array<Row & { prevP50: number | null }> {
  const byKey = new Map<string, Row[]>();
  for (const r of rows) {
    const k = `${r.screen}|${r.platform}|${r.cold}`;
    byKey.set(k, [...(byKey.get(k) ?? []), r]);
  }
  return [...byKey.values()]
    .map((list) => {
      const s = [...list].sort((a, b) => b.day.localeCompare(a.day));
      return { ...s[0], prevP50: s[1]?.p50 ?? null };
    })
    .sort((a, b) => Number(a.cold) - Number(b.cold) || a.screen.localeCompare(b.screen) || a.platform.localeCompare(b.platform));
}

export default function AdminScreenSpeed() {
  const { data, isLoading, error } = useQuery({
    queryKey: ["admin-screen-speed"],
    staleTime: 60_000,
    queryFn: async () => {
      const { data: d, error: e } = await supabase.rpc("admin_screen_speed" as never, { _days: 7 } as never);
      if (e) throw new Error((e as { message?: string }).message ?? "admin_screen_speed failed");
      const rows = ((d as { rows?: Row[] } | null)?.rows ?? []) as Row[];
      return latestPerScreen(rows);
    },
  });

  return (
    <section className="rounded-xl border border-border bg-card p-4" data-testid="admin-screen-speed">
      <h3 className="text-sm font-semibold">Speed per screen</h3>
      <p className="mb-3 text-xs text-muted-foreground">
        How long members wait from the tap until the screen shows. Typical = half of the opens were faster.
        Slowest = the slowest 1 in 20. Red = past the alarm line (typical {sec(LIMIT_P50)}, slowest {sec(LIMIT_P95)}); an alarm e-mail goes out after 30 slow opens in a day.
      </p>
      {isLoading ? (
        <p className="text-xs text-muted-foreground">Loading…</p>
      ) : error ? (
        <p className="text-xs text-destructive">Could not read the speed numbers: {(error as Error).message}</p>
      ) : !data || data.length === 0 ? (
        <p className="text-xs text-muted-foreground">No screen timings yet — they start arriving once members use the new version.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1 pr-2">Screen</th><th className="pr-2">App</th><th className="pr-2">Day</th>
                <th className="pr-2 text-right">Opens</th><th className="pr-2 text-right">Typical</th>
                <th className="pr-2 text-right">Slowest</th><th className="text-right">Day before</th>
              </tr>
            </thead>
            <tbody>
              {data.map((r) => (
                <tr key={`${r.screen}-${r.platform}-${r.cold}`} className="border-t border-border/50">
                  <td className="py-1 pr-2">{SCREEN_NAMES[r.screen] ?? r.screen}{r.cold ? " (app start)" : ""}</td>
                  <td className="pr-2">{APP[r.platform] ?? r.platform}</td>
                  <td className="pr-2">{r.day}</td>
                  <td className="pr-2 text-right">{r.n}</td>
                  <td className={`pr-2 text-right ${!r.cold && r.p50 > LIMIT_P50 ? "font-semibold text-destructive" : ""}`}>{sec(r.p50)}</td>
                  <td className={`pr-2 text-right ${!r.cold && r.p95 > LIMIT_P95 ? "font-semibold text-destructive" : ""}`}>{sec(r.p95)}</td>
                  <td className="text-right text-muted-foreground">{r.prevP50 === null ? "—" : sec(r.prevP50)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

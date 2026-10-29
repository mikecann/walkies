// A Threadbear panel (Threadbear's docs/protocol.md, "Patches") with Walkies'
// headline numbers from production: people, walks, suburbs, secrets and the
// suburb research. It reads them with `npx convex run --prod stats:overview`
// (convex/stats.ts, counts only), which uses Mike's Convex login, and keeps the
// answer for five minutes so the panel's refresh every 15 seconds doesn't ask
// production each time.

type Overview = {
  users: { total: number; new7d: number; walked7d: number; walked30d: number };
  walks: { total: number; last7d: number; km: number; tiles: number };
  regions: { suburbs: number; places: number };
  secretsFound: number;
  teams: number;
  lore: { places: Record<string, number>; waitingForMike: number; spentThisMonth: number };
  deletionsInProgress: number;
};

type Sh = (command: string) => Promise<string>;
type Row = { title: string; detail?: string; icon?: string; url?: string; tone?: "attention" | "failed" | "done" };

const KEEP_MS = 5 * 60 * 1000;
const DASHBOARD = "https://dashboard.convex.dev/d/savory-bee-296";

let cached: { at: number; value: Overview } | undefined;
let pending: Promise<Overview> | undefined;

async function overview(sh: Sh): Promise<Overview> {
  if (cached && Date.now() - cached.at < KEEP_MS) return cached.value;
  // One fetch at a time: the list, badge and summary ask together.
  pending ??= sh("npx convex run --prod stats:overview")
    .then((out) => {
      const value = JSON.parse(out.slice(out.indexOf("{"))) as Overview;
      cached = { at: Date.now(), value };
      return value;
    })
    .finally(() => {
      pending = undefined;
    });
  return pending;
}

const plural = (n: number, one: string, many = `${one}s`) => `${n.toLocaleString("en-AU")} ${n === 1 ? one : many}`;

export default {
  icon: "figure.walk",
  panels: [
    {
      title: "Walkies stats",
      icon: "chart.bar",
      note: "Production, counts only, refreshed every 5 minutes",
      badge: async ({ sh }: { sh: Sh }) => (await overview(sh)).lore.waitingForMike,
      summary: async ({ sh }: { sh: Sh }) => {
        const o = await overview(sh);
        return `${plural(o.users.total, "person", "people")} · ${plural(o.walks.total, "walk")} · ${plural(o.regions.suburbs, "suburb")}`;
      },
      items: async ({ sh }: { sh: Sh }): Promise<Row[]> => {
        let o: Overview;
        try {
          o = await overview(sh);
        } catch (error) {
          return [{ title: "Couldn't read production", detail: String(error).slice(0, 200), icon: "exclamationmark.triangle", tone: "failed" }];
        }
        const research = Object.entries(o.lore.places)
          .sort(([, a], [, b]) => b - a)
          .map(([kind, n]) => `${n} ${kind}`)
          .join(" · ");
        const rows: Row[] = [
          {
            title: plural(o.users.total, "person", "people"),
            detail: `${o.users.new7d} new this week · ${o.users.walked7d} walked this week · ${o.users.walked30d} this month`,
            icon: "person.2",
            url: `${DASHBOARD}/data?table=users`,
          },
          {
            title: plural(o.walks.total, "walk"),
            detail: `${o.walks.last7d} this week · ${o.walks.km.toLocaleString("en-AU")} km · ${o.walks.tiles.toLocaleString("en-AU")} tiles`,
            icon: "figure.walk",
          },
          {
            title: plural(o.regions.suburbs, "suburb"),
            detail: plural(o.regions.places, "place") + " added by people",
            icon: "map",
          },
          { title: plural(o.secretsFound, "secret") + " found", icon: "sparkles" },
          { title: plural(o.teams, "team"), icon: "person.3" },
          {
            title: research ? `Research: ${research}` : "Research: none yet",
            detail: `$${o.lore.spentThisMonth.toFixed(2)} this month`,
            icon: "books.vertical",
          },
        ];
        if (o.lore.waitingForMike > 0)
          rows.push({ title: `${plural(o.lore.waitingForMike, "secret")} waiting for your OK`, icon: "checkmark.seal", tone: "attention" });
        if (o.deletionsInProgress > 0)
          rows.push({ title: `${plural(o.deletionsInProgress, "account deletion")} in progress`, icon: "trash", tone: "attention" });
        return rows;
      },
    },
  ],
};

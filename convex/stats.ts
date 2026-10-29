import { v } from "convex/values";
import { internalQuery } from "./_generated/server";

// The headline numbers for Mike's Threadbear panel (.threadbear/patches/stats.ts):
// `npx convex run --prod stats:overview`. Counts only, never anyone's name, email
// or location. Internal, so only the CLI with Mike's login can call it. The tables
// are small (people and walks in the hundreds), so it reads them whole.

const day = 24 * 60 * 60 * 1000;

export const overview = internalQuery({
  args: {},
  returns: v.object({
    users: v.object({ total: v.number(), new7d: v.number(), walked7d: v.number(), walked30d: v.number() }),
    walks: v.object({ total: v.number(), last7d: v.number(), km: v.number(), tiles: v.number() }),
    regions: v.object({ suburbs: v.number(), places: v.number() }),
    secretsFound: v.number(),
    teams: v.number(),
    lore: v.object({
      places: v.record(v.string(), v.number()),
      waitingForMike: v.number(),
      spentThisMonth: v.number(),
    }),
    deletionsInProgress: v.number(),
  }),
  handler: async (ctx) => {
    const now = Date.now();

    // People: everyone signed up, minus duplicates folded into another account
    // and deleted accounts (both stay as rows).
    const people = (await ctx.db.query("users").collect()).filter(
      (user) => user.mergedInto === undefined && user.deletedAt === undefined,
    );

    const walks = await ctx.db.query("walks").collect();
    const walkedSince = (since: number) =>
      new Set(walks.filter((walk) => walk.endedAt >= since).map((walk) => walk.userId)).size;

    // A region is a suburb with shared map data (osmId 0 and -2 are the
    // Nominatim and Overpass throttles, not places); places are each person's own.
    const suburbs = (await ctx.db.query("placeData").collect()).filter((row) => row.osmId > 0).length;
    const places = (await ctx.db.query("places").collect()).length;

    const lorePlaces: Record<string, number> = {};
    for (const row of await ctx.db.query("lorePlaces").collect())
      lorePlaces[row.state.kind] = (lorePlaces[row.state.kind] ?? 0) + 1;
    const waitingForMike = (
      await ctx.db.query("loreEntries").withIndex("by_review", (q) => q.eq("state.kind", "pending")).collect()
    ).length;
    // loreSpend's day is "YYYY-MM-DD" in UTC, as the caps count it.
    const month = new Date(now).toISOString().slice(0, 7);
    const spend = await ctx.db
      .query("loreSpend")
      .withIndex("by_day", (q) => q.gte("day", `${month}-01`).lte("day", `${month}-31`))
      .collect();

    return {
      users: {
        total: people.length,
        new7d: people.filter((user) => user._creationTime >= now - 7 * day).length,
        walked7d: walkedSince(now - 7 * day),
        walked30d: walkedSince(now - 30 * day),
      },
      walks: {
        total: walks.length,
        last7d: walks.filter((walk) => walk.endedAt >= now - 7 * day).length,
        km: Math.round(walks.reduce((sum, walk) => sum + walk.distance, 0) / 100) / 10,
        tiles: walks.reduce((sum, walk) => sum + walk.newTiles, 0),
      },
      regions: { suburbs, places },
      secretsFound: (await ctx.db.query("secrets").collect()).length,
      teams: (await ctx.db.query("teams").collect()).length,
      lore: {
        places: lorePlaces,
        waitingForMike,
        spentThisMonth: Math.round(spend.reduce((sum, row) => sum + row.cost, 0) * 100) / 100,
      },
      deletionsInProgress: (
        await ctx.db.query("accountDeletions").withIndex("by_finishedAt_lastStepAt", (q) => q.eq("finishedAt", undefined)).collect()
      ).length,
    };
  },
});

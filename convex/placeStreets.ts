"use node";
// The heavy half of fetching a place's streets: Overpass's `out geom` answer, the ways
// built from it and the JSON file written out. For a big suburb that's well over the
// default runtime's 64 MB (WALKIES-6 killed the warm queue's worker that way), and Node
// actions get 512 MB. It runs as its own action, so if even that isn't enough, the
// error comes back to the caller's runAction and places.ts records a failed fetch
// rather than dying with it.
import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { fetchJSON, OsmError, overpassEndpoints, TooBig, waysInTiles, type Box } from "./osm";
import { boundaryBox, walkableBoxQuery, type PlaceData } from "./placeData";

// One Overpass answer bigger than this is fetched in quarters instead. Parsed, an
// answer takes several times its size, and one suburb ran even 512 MB out (WALKIES-9).
const answerCap = 48 * 1024 * 1024;
// Up to 64 tiles. A suburb that needs more than that isn't one anybody walks round.
const maxDepth = 3;
// Overpass's gateway gives up on a heavy query with a 504 (WALKIES-8), and Overpass
// itself says so in a remark when it runs out of time or memory.
const tooHeavy = /timed out|out of memory/i;
// No new request starts after this. One can still take 135 s, so this keeps the whole
// download inside the 7-minute Overpass slot. Birmingham (4 tiles) took 3.6 minutes.
const timeLimit = 4.5 * 60 * 1000;

/** One box's answer, from whichever server gives one. TooBig if it's too much for one
 * go, so waysInTiles splits it: over the size cap, a 504 from Overpass's gateway, or a
 * remark that it ran out of time or memory. Those go straight to splitting rather than
 * asking the other server, which has the same data and would take as long again. */
async function fetchBox(box: Box, deadline: number): Promise<unknown> {
  const body = new URLSearchParams({ data: walkableBoxQuery(box) }).toString();
  let lastError: unknown;
  for (const endpoint of overpassEndpoints) {
    if (Date.now() > deadline) throw new Error("Ran out of time fetching this place's streets in tiles");
    const started = Date.now();
    const where = `${box.south.toFixed(3)},${box.west.toFixed(3)},${box.north.toFixed(3)},${box.east.toFixed(3)} from ${new URL(endpoint).host}`;
    try {
      const answer = await fetchJSON(endpoint, 135_000, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body }, answerCap);
      const remark = (answer as { remark?: unknown } | null)?.remark;
      if (typeof remark === "string" && tooHeavy.test(remark)) throw new TooBig(remark);
      console.log(`Overpass ${where}: ok in ${Math.round((Date.now() - started) / 1000)} s`);
      return answer;
    } catch (error) {
      const heavy = error instanceof TooBig || (error instanceof OsmError && error.status === 504);
      console.log(`Overpass ${where}: ${heavy ? "too big, splitting" : "failed"} after ${Math.round((Date.now() - started) / 1000)} s (${error instanceof Error ? error.message : error})`);
      if (heavy) throw error instanceof TooBig ? error : new TooBig((error as Error).message);
      lastError = error;
    }
  }
  throw lastError ?? new Error("No street data");
}

/** Fetches the walkable ways inside `boundary` (JSON, as boundaryFromNominatim gives
 * it) and stores the place's street file. Call it holding the Overpass slot. */
export const download = internalAction({
  // A string, as one of a big suburb's rings can have more points than Convex lets an array hold.
  args: { boundary: v.string() },
  returns: v.id("_storage"),
  handler: async (ctx, args) => {
    const boundary = JSON.parse(args.boundary) as PlaceData["boundary"];
    const deadline = Date.now() + timeLimit;
    const ways = await waysInTiles(boundaryBox(boundary), (box) => fetchBox(box, deadline), maxDepth);
    // The same JSON as JSON.stringify({ boundary, ways }), written from each way's
    // own JSON so the whole list never has to be built as objects.
    const parts: string[] = [`{"boundary":${JSON.stringify(boundary)},"ways":[`];
    ways.forEach((way, i) => parts.push(i === 0 ? way : `,${way}`));
    parts.push("]}");
    return await ctx.storage.store(new Blob(parts, { type: "application/json" }));
  },
});

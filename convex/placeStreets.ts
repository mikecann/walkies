"use node";
// The heavy half of fetching a place's streets: Overpass's `out geom` answer, the ways
// built from it and the JSON file written out. For a big suburb that's well over the
// default runtime's 64 MB (WALKIES-6 killed the warm queue's worker that way), and Node
// actions get 512 MB. It runs as its own action, so if even that isn't enough, the
// error comes back to the caller's runAction and places.ts records a failed fetch
// rather than dying with it.
import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { fetchJSON, OsmError, overpassEndpoints, tileWays, TooBig, utf8Length, waysInTiles, type Box } from "./osm";
import { boundaryBox, walkableBoxQuery, type PlaceData } from "./placeData";

// One Overpass answer bigger than this is fetched in quarters instead. Parsed, an
// answer takes several times its size, and one suburb ran even 512 MB out (WALKIES-9).
const answerCap = 48 * 1024 * 1024;
// Up to 64 tiles. A suburb that needs more than that isn't one anybody walks round.
const maxDepth = 3;
// The whole street file, in UTF-8 bytes. Birmingham is 15 MB; past this a place isn't
// worth caching, and the ways, the file being saved and one tile being parsed all fit
// in 512 MB.
const fileCap = 64 * 1024 * 1024;
// Overpass's gateway gives up on a heavy query with a 504 (WALKIES-8), and Overpass
// itself says so in a remark when it runs out of time or memory ("Query timed out in
// ...", "runtime error: timeout", "Query run out of memory using about 2048 MB").
const tooHeavy = /timed out|timeout|out of memory/i;
// The Overpass slot is held for 7 minutes; finish inside it.
const slotTime = 6.5 * 60 * 1000;
// Kept back at the end for saving the file and recording it.
const saveTime = 20_000;
const requestTimeout = 135_000;

/** Asks the Overpass servers for one box, in turn, starting with whichever last
 * answered. Throws TooBig if it's too much for one go, so waysInTiles splits it: over
 * the size cap, a 504 from the gateway, or a remark that Overpass ran out of time or
 * memory. A 504 can also be one server having a bad time, so the other server is asked
 * first from then on, and for a box as small as it goes, before giving up. */
function overpassFetcher(end: number) {
  let first = 0;
  return async function fetchBox(box: Box, smallest: boolean): Promise<{ id: number; json: string }[]> {
    const body = new URLSearchParams({ data: walkableBoxQuery(box) }).toString();
    const order = [first, ...overpassEndpoints.keys()].filter((i, n, all) => all.indexOf(i) === n);
    let lastError: unknown;
    for (const index of order) {
      const endpoint = overpassEndpoints[index];
      const timeout = Math.min(requestTimeout, end - Date.now());
      if (timeout < 10_000) throw new Error("Ran out of time fetching this place's streets");
      const started = Date.now();
      const where = `${box.south.toFixed(3)},${box.west.toFixed(3)},${box.north.toFixed(3)},${box.east.toFixed(3)} from ${new URL(endpoint).host}`;
      try {
        const answer = await fetchJSON(endpoint, timeout, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body }, answerCap);
        const remark = (answer as { remark?: unknown } | null)?.remark;
        if (typeof remark === "string" && tooHeavy.test(remark)) throw new TooBig(remark);
        // Read here, so a broken answer from one server means asking the other.
        const ways = tileWays(answer);
        console.log(`Overpass ${where}: ok in ${Math.round((Date.now() - started) / 1000)} s`);
        first = index;
        return ways;
      } catch (error) {
        const gateway = error instanceof OsmError && error.status === 504;
        // Our own timeout firing means Overpass was still working on it after 135 s.
        const slow = error instanceof Error && error.name === "AbortError";
        const heavy = gateway || slow || error instanceof TooBig;
        console.log(`Overpass ${where}: ${heavy && !smallest ? "too big, splitting" : "failed"} after ${Math.round((Date.now() - started) / 1000)} s (${error instanceof Error ? error.message : error})`);
        lastError = heavy ? (error instanceof TooBig ? error : new TooBig((error as Error).message)) : error;
        // A server that's down or stuck gets passed over for the other from now on.
        if (gateway || slow) first = order.find((i) => i !== index) ?? index;
        // Over the size cap is the same on either server. Otherwise split now, unless it's
        // as small as it goes, and then the other server gets a go.
        if (error instanceof TooBig && !tooHeavy.test(error.message)) throw lastError;
        if (heavy && !smallest) throw lastError;
      }
    }
    throw lastError ?? new Error("No street data");
  };
}

/** Fetches the walkable ways inside `boundary` (JSON, as boundaryFromNominatim gives
 * it) and stores the place's street file, done by `deadline`. Call it holding the
 * Overpass slot. */
export const download = internalAction({
  // A string, as one of a big suburb's rings can have more points than Convex lets an array hold.
  args: { boundary: v.string(), deadline: v.number() },
  returns: v.id("_storage"),
  handler: async (ctx, args) => {
    const boundary = JSON.parse(args.boundary) as PlaceData["boundary"];
    const end = Math.min(args.deadline, Date.now() + slotTime) - saveTime;
    // The same JSON as JSON.stringify({ boundary, ways }), written from each way's
    // own JSON so the whole list never has to be built as objects.
    const head = `{"boundary":${JSON.stringify(boundary)},"ways":[`;
    // The cap is for the whole file, so the boundary comes out of it.
    const ways = await waysInTiles(boundaryBox(boundary), overpassFetcher(end), maxDepth, fileCap - utf8Length(head) - 2);
    const parts: string[] = [head];
    ways.forEach((way, i) => parts.push(i === 0 ? way : `,${way}`));
    parts.push("]}");
    return await ctx.storage.store(new Blob(parts, { type: "application/json" }));
  },
});

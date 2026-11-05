"use node";
// The heavy half of fetching a place's streets: Overpass's `out geom` answer, the ways
// built from it and the JSON file written out. For a big suburb that's well over the
// default runtime's 64 MB (WALKIES-6 killed the warm queue's worker that way), and Node
// actions get 512 MB. It runs as its own action, so if even that isn't enough, the
// error comes back to the caller's runAction and places.ts records a failed fetch
// rather than dying with it.
import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { fetchJSON, overpassEndpoints } from "./osm";
import { walkableQuery, waysFromOverpass, type PlaceData } from "./placeData";

/** Fetches the walkable ways inside `boundary` (JSON, as boundaryFromNominatim gives
 * it) and stores the place's street file. Call it holding the Overpass slot. */
export const download = internalAction({
  // A string, as one of a big suburb's rings can have more points than Convex lets an array hold.
  args: { boundary: v.string() },
  returns: v.id("_storage"),
  handler: async (ctx, args) => {
    const boundary = JSON.parse(args.boundary) as PlaceData["boundary"];
    const body = new URLSearchParams({ data: walkableQuery(boundary) }).toString();
    let lastError: unknown;
    for (const endpoint of overpassEndpoints) {
      try {
        const ways = waysFromOverpass(await fetchJSON(endpoint, 135_000, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body }));
        return await ctx.storage.store(new Blob([JSON.stringify({ boundary, ways } satisfies PlaceData)], { type: "application/json" }));
      } catch (error) { lastError = error; }
    }
    throw lastError ?? new Error("No street data");
  },
});

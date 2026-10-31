// Secrets for new suburbs, server side. What the phones ask for (forPlace), what
// starts research (a walk in a place that has none), the queue that keeps runs inside
// the spending caps, and Mike's review. The run itself is lorePipeline.ts, and the
// contract the apps build against is shared/lore-api.md.
import { ConvexError, v } from "convex/values";
import { restart, vResultValidator, vWorkflowId } from "@convex-dev/workflow";
import { paginationOptsValidator } from "convex/server";
import { components, internal } from "./_generated/api";
import type { DataModel, Doc, Id } from "./_generated/dataModel";
import {
  env, internalAction, query, type ActionCtx, type MutationCtx as RawMutationCtx, type QueryCtx,
} from "./_generated/server";
import type { AppCtx, InternalCtx } from "@convex-dev/state-machines";
import { boundaryArea, boundingBox, fetchPage, insideBoundary } from "./loreChecks";
import {
  bundledOsmIds, caps, checksPerUserPerDay, day, journalKeep, maxRunning, minWalkedTiles, nearbyPerUserPerDay,
  nearbyPerUserPerMonth, nearbyReach, suburbArea, suburbsPerUserPerDay, suburbsPerUserPerMonth, walkCheck,
} from "./loreConfig";
import { autoOn, journalOf, placeRow } from "./loreMachines";
import { dayKey, monthOf, releaseStale, spentBetween } from "./loreRun";
import { clientStatus, vLoreReview } from "./loreStates";
import { workflow } from "./loreWorkflow";
import { loreEntry, lorePlace, machines, vHistory } from "./machines";
import { boundaryFromNominatim, type PlaceData } from "./placeData";
import { nominatim } from "./places";
import { currentUserId } from "./users";

export { autoOn, workflow };

// The catalog's builders (machines.ts): their db can't write a machine's state, and the
// internal ones can send the machines' `server` events. What the phones read and the
// actions stay on Convex's own.
const { mutation, internalMutation, internalQuery } = machines;
/** A handler's ctx in the catalog's internalMutation, for the helpers it calls. */
type MutationCtx = AppCtx<DataModel> & InternalCtx & Pick<RawMutationCtx, "runMutation" | "runQuery">;

/** A place nobody's queue ever got to is as good as unknown: the next walk there can queue it again. */
const known = (row: Doc<"lorePlaces"> | null) => row !== null && row.state.kind !== "expired";
/** Known, and not just waiting for being next to someone (lore:prepare): a walk there moves that up. */
const settled = (row: Doc<"lorePlaces"> | null) => known(row) && !(row!.state.kind === "queued" && row!.state.nearby);

const vPlace = v.object({ name: v.string(), lat: v.number(), lon: v.number() });

/** One secret as the phones get it: the bundled LoreEntry JSON, plus where its sticker is. */
export const vLiveEntry = v.object({
  id: v.string(),
  title: v.string(),
  body: v.string(),
  category: v.string(),
  place: v.optional(vPlace),
  sticker: v.string(),
  sources: v.array(v.string()),
  suburb: v.string(),
  stickerUrl: v.union(v.string(), v.null()),
});

/**
 * The server's secrets for a place (`osmId` is its OSM relation). `status` is
 * "bundled" when the app ships its own, "none" before anyone's walked there, "queued"
 * or "researching" while it's being written (show the waiting card), then "ready",
 * "quiet" (not much to find; whatever was found is still here) or "failed". Only
 * live secrets come back, never ones waiting for review or hidden. `version` goes up
 * whenever they change. See shared/lore-api.md.
 */
export const forPlace = query({
  args: { osmId: v.number() },
  returns: v.object({
    status: v.union(
      v.literal("bundled"), v.literal("none"), v.literal("queued"), v.literal("researching"),
      v.literal("ready"), v.literal("quiet"), v.literal("failed"),
    ),
    version: v.number(),
    entries: v.array(vLiveEntry),
  }),
  handler: async (ctx, { osmId }) => {
    if (await currentUserId(ctx) === null) throw new ConvexError("Not signed in");
    if (bundledOsmIds.has(osmId)) return { status: "bundled" as const, version: 0, entries: [] };
    const row = await placeRow(ctx, osmId);
    if (row === null) return { status: "none" as const, version: 0, entries: [] };
    const live = [...await withReview(ctx, osmId, "auto"), ...await withReview(ctx, osmId, "approved")]
      .sort((a, b) => a.entryId.localeCompare(b.entryId));
    return {
      status: clientStatus(row.state),
      version: row.version,
      entries: await Promise.all(live.map(async (entry) => ({
        id: entry.entryId,
        title: entry.title,
        body: entry.body,
        category: entry.category,
        ...(entry.place ? { place: entry.place } : {}),
        sticker: entry.sticker,
        sources: entry.sources,
        suburb: entry.suburb,
        stickerUrl: entry.stickerFile ? await ctx.storage.getUrl(entry.stickerFile) : null,
      }))),
    };
  },
});

async function withReview(ctx: QueryCtx, osmId: number, review: Doc<"loreEntries">["state"]["kind"]) {
  return await ctx.db.query("loreEntries").withIndex("by_osm_review", (q) => q.eq("osmId", osmId).eq("state.kind", review)).collect();
}

// What starts a run. The server only learns where someone walked when their phone
// saves the place (the city file has its OSM relation and the tiles walked in it) and
// when it saves a walk. Neither file can be trusted, since it comes from the phone,
// so before queuing anything the server checks for itself that the relation is a
// suburb-sized admin boundary and that one of the person's own saved walks went into
// it, and each person can only start so many suburbs a day and a month.

/**
 * Called by sync:savePlace with the copy it kept. Reads the file in the background
 * unless this place has already been looked at, so most saves cost nothing.
 */
export async function noticePlace(ctx: RawMutationCtx, place: Doc<"places">) {
  if (!autoOn()) return;
  if (place.osmId !== undefined && (bundledOsmIds.has(place.osmId) || place.loreNoSuburb || settled(await placeRow(ctx, place.osmId)))) return;
  await ctx.scheduler.runAfter(0, internal.lore.readPlace, { placeId: place._id });
}

/** Places a walk can get looked at, so a long list doesn't start a burst of checks. */
const placesPerWalk = 10;

/**
 * Called by sync:saveWalk for a new walk. The phones upload places before walks, so a
 * person's first walk arrives after the place it was in was turned down for having no
 * walk; this looks at their places again now there is one.
 */
export async function noticeWalk(ctx: RawMutationCtx, userId: Id<"users">, walkId: Id<"walks">) {
  if (!autoOn()) return;
  const places = await ctx.db.query("places").withIndex("by_user_client", (q) => q.eq("userId", userId)).collect();
  let looked = 0;
  for (const place of places) {
    if (looked >= placesPerWalk) break;
    if (place.walkedTiles !== undefined && place.walkedTiles < minWalkedTiles) continue;
    if (place.osmId !== undefined && (bundledOsmIds.has(place.osmId) || place.loreNoSuburb || settled(await placeRow(ctx, place.osmId)))) continue;
    await ctx.scheduler.runAfter(0, internal.lore.readPlace, { placeId: place._id, walkId });
    looked++;
  }
}

export const placeFile = internalQuery({
  args: { placeId: v.id("places") },
  returns: v.union(v.null(), v.object({ userId: v.id("users"), file: v.id("_storage") })),
  handler: async (ctx, { placeId }) => {
    const place = await ctx.db.get("places", placeId);
    return place && { userId: place.userId, file: place.file };
  },
});

/** A cached street file for the relation, if there is one (places.ts keeps them). */
export const placeDataFile = internalQuery({
  args: { osmId: v.number() },
  returns: v.union(v.null(), v.id("_storage")),
  handler: async (ctx, { osmId }) => {
    const row = await ctx.db.query("placeData").withIndex("by_osm", (q) => q.eq("osmId", osmId)).unique();
    return row?.file ?? null;
  },
});

/** Someone's newest saved walks, the one just saved first, for the walk check. */
export const recentWalks = internalQuery({
  args: { userId: v.id("users"), walkId: v.optional(v.id("walks")) },
  returns: v.array(v.id("_storage")),
  handler: async (ctx, { userId, walkId }) => {
    const walks = await ctx.db.query("walks").withIndex("by_user_client", (q) => q.eq("userId", userId)).collect();
    walks.sort((a, b) => Number(b._id === walkId) - Number(a._id === walkId) || b.endedAt - a.endedAt);
    return walks.slice(0, walkCheck.walks).map((walk) => walk.file);
  },
});

type Boundary = PlaceData["boundary"];

/** The relation's outline from the street cache, when it's there and small enough to read. */
async function cachedBoundary(ctx: ActionCtx, osmId: number): Promise<Boundary | null> {
  const file = await ctx.runQuery(internal.lore.placeDataFile, { osmId });
  const blob = file && await ctx.storage.get(file);
  // The file holds every street too; a big one isn't worth reading, and isn't a suburb.
  if (!blob || blob.size > 8_000_000) return null;
  try {
    const boundary = (JSON.parse(await blob.text()) as Partial<PlaceData>).boundary;
    return Array.isArray(boundary) && boundary.length > 0 ? boundary : null;
  } catch {
    return null;
  }
}

/** Why a boundary isn't a suburb's size, or null when it is. */
function sizeProblem(boundary: Boundary): string | null {
  const area = boundaryArea(boundary);
  return area > suburbArea.max ? "too big" : area < suburbArea.min ? "too small" : null;
}

/**
 * Whether one of the person's newest walks has good GPS fixes inside the boundary, or
 * with `reach`, one good fix within that many metres of its bounding box.
 */
async function walkedInside(ctx: ActionCtx, userId: Id<"users">, boundary: Boundary, walkId?: Id<"walks">, reach?: number): Promise<boolean> {
  const inner = boundingBox(boundary);
  // Metres to degrees, generously at the box's widest latitude.
  const lat = reach ? reach / 111_000 : 0;
  const lon = reach ? reach / (111_000 * Math.max(0.1, Math.cos(Math.max(Math.abs(inner.south), Math.abs(inner.north)) * Math.PI / 180))) : 0;
  const box = { south: inner.south - lat, north: inner.north + lat, west: inner.west - lon, east: inner.east + lon };
  for (const file of await ctx.runQuery(internal.lore.recentWalks, { userId, ...(walkId ? { walkId } : {}) })) {
    const blob = await ctx.storage.get(file);
    if (!blob) continue;
    let points: unknown;
    try {
      points = (JSON.parse(await blob.text()) as { points?: unknown }).points;
    } catch {
      continue;
    }
    if (!Array.isArray(points)) continue;
    let inside = 0;
    for (const point of points as { lat?: unknown; lon?: unknown; accuracy?: unknown }[]) {
      const { lat, lon, accuracy } = point ?? {};
      if (typeof lat !== "number" || typeof lon !== "number" || typeof accuracy !== "number") continue;
      if (accuracy < 0 || accuracy > walkCheck.maxAccuracy) continue;
      if (lat < box.south || lat > box.north || lon < box.west || lon > box.east) continue;
      if (reach !== undefined) return true;
      if (insideBoundary(boundary, lat, lon) && ++inside >= walkCheck.minPoints) return true;
    }
  }
  return false;
}

/**
 * Reads a saved place's file for its OSM relation and walked tiles, then decides
 * whether research should start there (see above). Says what it decided, for the
 * tests and logs. `walkId` is a walk just saved, which gets looked at first.
 */
export const readPlace = internalAction({
  args: { placeId: v.id("places"), walkId: v.optional(v.id("walks")) },
  returns: v.string(),
  handler: async (ctx, { placeId, walkId }): Promise<string> => {
    const place = await ctx.runQuery(internal.lore.placeFile, { placeId });
    // Gone already: deleted, or replaced by a newer copy, which gets its own look.
    const blob = place && await ctx.storage.get(place.file);
    if (!place || !blob) return "gone";
    let city: { osmId?: unknown; name?: unknown; visited?: unknown };
    try {
      city = JSON.parse(await blob.text());
    } catch {
      return "unreadable";
    }
    const osmId = city.osmId;
    // Places drawn before they kept their relation, or found some other way, have none.
    if (typeof osmId !== "number" || !Number.isSafeInteger(osmId) || osmId <= 0) return "no relation";
    const name = typeof city.name === "string" ? city.name : "";
    const walkedTiles = Array.isArray(city.visited) ? city.visited.length : 0;
    const first: string = await ctx.runMutation(internal.lore.notePlace, { userId: place.userId, placeId, osmId, walkedTiles });
    if (first !== "check") return first;
    const notSuburb = async (why: string) => {
      await ctx.runMutation(internal.lore.markNoSuburb, { placeId, osmId });
      return `not a suburb (${why})`;
    };
    // The walk check first, from the street cache when it has the outline, as it costs
    // nothing; Nominatim is shared by everyone and only gets asked once that passes.
    let boundary = await cachedBoundary(ctx, osmId);
    if (boundary) {
      const size = sizeProblem(boundary);
      if (size) return await notSuburb(size);
      if (!await walkedInside(ctx, place.userId, boundary, walkId)) return "not walked";
    }
    const answer = await nominatim(ctx, "lookup", {
      osm_ids: `R${osmId}`, format: "jsonv2", ...(boundary ? {} : { polygon_geojson: "1", polygon_threshold: "0.0001" }),
    }).catch(() => null);
    const item = Array.isArray(answer)
      ? (answer as { osm_type?: string; osm_id?: number; category?: string; type?: string }[]).find((i) => i.osm_type === "relation" && i.osm_id === osmId)
      : undefined;
    if (!item) return "unknown";
    if (item.category !== "boundary" || item.type !== "administrative") return await notSuburb(`${item.category}=${item.type}`);
    if (!boundary) {
      try {
        boundary = boundaryFromNominatim(answer, osmId).boundary;
      } catch {
        return "unknown";
      }
      const size = sizeProblem(boundary);
      if (size) return await notSuburb(size);
      if (!await walkedInside(ctx, place.userId, boundary, walkId)) return "not walked";
    }
    return await ctx.runMutation(internal.lore.noteWalked, { userId: place.userId, placeId, osmId, name, walkedTiles });
  },
});

/** The start of the UTC day and month `ms` is in. */
function dayAndMonthStart(ms: number) {
  const day = dayKey(ms);
  return { day: Date.parse(`${day}T00:00:00Z`), month: Date.parse(`${day.slice(0, 7)}-01T00:00:00Z`) };
}

/** Why this person's walk can't start research here, or null if it can (so far). */
async function whyNot(ctx: MutationCtx, userId: Id<"users">, osmId: number, walkedTiles: number, place: Doc<"places"> | null) {
  if (!autoOn()) return "off";
  if (bundledOsmIds.has(osmId)) return "bundled";
  // Someone else got here first. Whatever state it's in, this walk pays nothing.
  if (settled(await placeRow(ctx, osmId))) return "known";
  if (place?.loreNoSuburb && place.osmId === osmId) return "not a suburb";
  if (walkedTiles < minWalkedTiles) return "not walked";
  // Past either limit nothing is saved, so a sync after it resets tries again.
  const since = dayAndMonthStart(Date.now());
  const started = (await ctx.db.query("loreRequests").withIndex("by_user_at", (q) => q.eq("userId", userId).gte("at", since.month)).collect()).filter((r) => !r.nearby);
  if (started.length >= suburbsPerUserPerMonth || started.filter((r) => r.at >= since.day).length >= suburbsPerUserPerDay) return "too many";
  return null;
}

/**
 * The first look at a place, before anything is fetched: keeps its relation and walked
 * tiles, and says "check" if the server should look further, which counts towards the
 * person's checks for the day (each may ask Nominatim).
 */
export const notePlace = internalMutation({
  args: { userId: v.id("users"), placeId: v.id("places"), osmId: v.number(), walkedTiles: v.number() },
  returns: v.string(),
  handler: async (ctx, { userId, placeId, osmId, walkedTiles }) => {
    const place = await ctx.db.get("places", placeId);
    if (place && (place.osmId !== osmId || place.walkedTiles !== walkedTiles)) {
      await ctx.db.patch("places", placeId, { osmId, walkedTiles, ...(place.osmId !== osmId ? { loreNoSuburb: undefined } : {}) });
    }
    const why = await whyNot(ctx, userId, osmId, walkedTiles, place);
    if (why !== null) return why;
    const now = Date.now();
    const calls = await ctx.db.query("loreCalls").withIndex("by_user", (q) => q.eq("userId", userId)).unique();
    const today = calls !== null && dayKey(calls.windowStart) === dayKey(now);
    if (today && calls.count >= checksPerUserPerDay) return "checked enough";
    if (calls === null) await ctx.db.insert("loreCalls", { userId, windowStart: now, count: 1 });
    else await ctx.db.patch("loreCalls", calls._id, { windowStart: today ? calls.windowStart : now, count: today ? calls.count + 1 : 1 });
    return "check";
  },
});

/** The relation isn't a suburb-sized admin boundary, so this place is never looked at again. */
export const markNoSuburb = internalMutation({
  args: { placeId: v.id("places"), osmId: v.number() }, returns: v.null(),
  handler: async (ctx, { placeId, osmId }) => {
    const place = await ctx.db.get("places", placeId);
    if (place?.osmId === osmId) await ctx.db.patch("places", placeId, { loreNoSuburb: true });
    return null;
  },
});

/**
 * Queues research for a place someone has added and walked in, once readPlace's checks
 * have passed, if nobody has yet. Says what it did, for the tests and logs.
 */
export const noteWalked = internalMutation({
  args: { userId: v.id("users"), placeId: v.id("places"), osmId: v.number(), name: v.string(), walkedTiles: v.number() },
  returns: v.union(
    v.literal("off"), v.literal("bundled"), v.literal("known"), v.literal("not a suburb"), v.literal("not walked"),
    v.literal("too many"), v.literal("queued"),
  ),
  handler: async (ctx, { userId, placeId, osmId, name, walkedTiles }) => {
    const place = await ctx.db.get("places", placeId);
    if (place && place.osmId !== osmId) await ctx.db.patch("places", placeId, { osmId });
    const why = await whyNot(ctx, userId, osmId, walkedTiles, place);
    if (why !== null) return why;
    await ctx.db.insert("loreRequests", { userId, osmId, at: Date.now() });
    await queue(ctx, osmId, name, { manual: false, requestedBy: userId });
    await startQueued(ctx);
    return "queued";
  },
});

// Getting ahead of people. The phone also says which suburbs are around the one it's
// in (lore:prepare), so their secrets are ready by the time anyone walks over the
// border. It's not believed either: the server checks each is a suburb-sized admin
// boundary that one of the person's own walks came within `nearbyReach` of, and these
// have their own per-person limits and wait behind places people have walked.

/** The most suburbs one lore:prepare call can ask about. */
const preparePerCall = 12;

/** Asks for secrets for the suburbs around where you are. Checked and queued in the background. */
export const prepare = mutation({
  args: { osmIds: v.array(v.number()) }, returns: v.null(),
  handler: async (ctx, { osmIds }): Promise<null> => {
    const userId = await currentUserId(ctx);
    if (userId === null) throw new ConvexError("Not signed in");
    if (!autoOn()) return null;
    const wanted = [...new Set(osmIds)].filter((id) => Number.isSafeInteger(id) && id > 0 && !bundledOsmIds.has(id)).slice(0, preparePerCall);
    for (const osmId of wanted) {
      if (known(await placeRow(ctx, osmId))) continue;
      await ctx.scheduler.runAfter(0, internal.lore.readNearby, { userId, osmId });
    }
    return null;
  },
});

/** Why this person can't queue a suburb for being nearby, or null if they can (so far). */
async function whyNotNearby(ctx: MutationCtx, userId: Id<"users">, osmId: number) {
  if (!autoOn()) return "off";
  if (bundledOsmIds.has(osmId)) return "bundled";
  if (known(await placeRow(ctx, osmId))) return "known";
  const since = dayAndMonthStart(Date.now());
  const started = (await ctx.db.query("loreRequests").withIndex("by_user_at", (q) => q.eq("userId", userId).gte("at", since.month)).collect()).filter((r) => r.nearby);
  if (started.length >= nearbyPerUserPerMonth || started.filter((r) => r.at >= since.day).length >= nearbyPerUserPerDay) return "too many";
  return null;
}

/** The first look at a nearby suburb: says "check" if it's worth fetching, which counts towards the person's checks. */
export const noteNearby = internalMutation({
  args: { userId: v.id("users"), osmId: v.number() }, returns: v.string(),
  handler: async (ctx, { userId, osmId }) => {
    const why = await whyNotNearby(ctx, userId, osmId);
    if (why !== null) return why;
    const now = Date.now();
    const calls = await ctx.db.query("loreCalls").withIndex("by_user", (q) => q.eq("userId", userId)).unique();
    const today = calls !== null && dayKey(calls.windowStart) === dayKey(now);
    if (today && calls.count >= checksPerUserPerDay) return "checked enough";
    if (calls === null) await ctx.db.insert("loreCalls", { userId, windowStart: now, count: 1 });
    else await ctx.db.patch("loreCalls", calls._id, { windowStart: today ? calls.windowStart : now, count: today ? calls.count + 1 : 1 });
    return "check";
  },
});

/**
 * Checks a suburb lore:prepare asked about, the same way readPlace does but with the
 * walk only having to come near it, and queues it. Says what it decided.
 */
export const readNearby = internalAction({
  args: { userId: v.id("users"), osmId: v.number() }, returns: v.string(),
  handler: async (ctx, { userId, osmId }): Promise<string> => {
    const first: string = await ctx.runMutation(internal.lore.noteNearby, { userId, osmId });
    if (first !== "check") return first;
    let boundary = await cachedBoundary(ctx, osmId);
    if (boundary) {
      const size = sizeProblem(boundary);
      if (size) return `not a suburb (${size})`;
      if (!await walkedInside(ctx, userId, boundary, undefined, nearbyReach)) return "not near";
    }
    const answer = await nominatim(ctx, "lookup", {
      osm_ids: `R${osmId}`, format: "jsonv2", ...(boundary ? {} : { polygon_geojson: "1", polygon_threshold: "0.0001" }),
    }).catch(() => null);
    const item = Array.isArray(answer)
      ? (answer as { osm_type?: string; osm_id?: number; category?: string; type?: string; name?: string }[])
        .find((i) => i.osm_type === "relation" && i.osm_id === osmId)
      : undefined;
    if (!item) return "unknown";
    if (item.category !== "boundary" || item.type !== "administrative") return `not a suburb (${item.category}=${item.type})`;
    if (!boundary) {
      try {
        boundary = boundaryFromNominatim(answer, osmId).boundary;
      } catch {
        return "unknown";
      }
      const size = sizeProblem(boundary);
      if (size) return `not a suburb (${size})`;
      if (!await walkedInside(ctx, userId, boundary, undefined, nearbyReach)) return "not near";
    }
    return await ctx.runMutation(internal.lore.queueNearby, { userId, osmId, name: typeof item.name === "string" ? item.name : "" });
  },
});

/** Queues a nearby suburb once readNearby's checks have passed, if nobody has yet. */
export const queueNearby = internalMutation({
  args: { userId: v.id("users"), osmId: v.number(), name: v.string() },
  returns: v.union(v.literal("off"), v.literal("bundled"), v.literal("known"), v.literal("too many"), v.literal("queued")),
  handler: async (ctx, { userId, osmId, name }) => {
    const why = await whyNotNearby(ctx, userId, osmId);
    if (why !== null) return why;
    await ctx.db.insert("loreRequests", { userId, osmId, at: Date.now(), nearby: true });
    await queue(ctx, osmId, name, { manual: false, requestedBy: userId, nearby: true });
    await startQueued(ctx);
    return "queued";
  },
});

/** Puts a place on the queue: a new row, or one that's finished or expired back on it. */
async function queue(ctx: MutationCtx, osmId: number, name: string, event: { manual: boolean; requestedBy?: Id<"users">; nearby?: boolean }) {
  const row = await placeRow(ctx, osmId);
  if (row === null) {
    return await lorePlace.create(ctx, { osmId, name, version: 0, attempts: 0, cost: 0, runCost: 0, segment: 0 }, { type: "QUEUE", ...event });
  }
  // An expired place someone walks again goes by the name their phone has now.
  if (row.state.kind === "expired" && name !== "" && name !== row.name) await ctx.db.patch("lorePlaces", row._id, { name });
  return await lorePlace.send(ctx, row._id, { type: "QUEUE", ...event });
}

// The queue. A run starts when a slot's free and it can't take today's or this
// month's spending over its cap, even if every run going spends its whole limit
// (which the holds on every call make the most it can spend). It takes turns between
// people: Mike's own asks first, then everyone's oldest before anyone's second.

/** What a pass over the queue did: the places it started, and why each place it couldn't start is held. */
type QueuePass = { started: number[]; held: Map<number, string>; failed: Map<number, string> };

/**
 * Goes through the queue in its order, calling `begin` for each place that can start
 * now, and says why the others are held by a cap. With no `begin` it only reads, as if
 * each had started, for lore:status.
 */
async function passQueue(ctx: QueryCtx, begin?: (row: Doc<"lorePlaces">) => Promise<string | null>): Promise<QueuePass> {
  const pass: QueuePass = { started: [], held: new Map(), failed: new Map() };
  const running = await ctx.db.query("lorePlaces").withIndex("by_state", (q) => q.eq("state.kind", "researching")).collect();
  const queued = await ctx.db.query("lorePlaces").withIndex("by_state", (q) => q.eq("state.kind", "queued")).collect();
  if (queued.length === 0) return pass;
  const today = dayKey(Date.now());
  const daily = await spentBetween(ctx, today, today);
  const monthly = await spentBetween(ctx, ...monthOf(today));
  // What the runs going now could still spend before their own limit stops them.
  let reserved = running.reduce((sum, row) => sum + Math.max(0, caps.perRun - row.runCost), 0);
  let slots = maxRunning - running.length;
  const turns = new Map<string, number>();
  const asked = (row: Doc<"lorePlaces">) => row.state.kind === "queued" || row.state.kind === "researching" ? row.state : null;
  for (const row of running) {
    const who = asked(row)?.requestedBy;
    if (who) turns.set(who, (turns.get(who) ?? 0) + 1);
  }
  const order = queued.map((row, index) => {
    // A retry nobody asked for takes its own turn.
    const who = asked(row)?.requestedBy ?? row._id;
    const turn = turns.get(who) ?? 0;
    turns.set(who, turn + 1);
    // Mike's own first, then places people have walked, then ones only next to them.
    const state = asked(row);
    return { row, index, turn: state?.manual ? -1 : state?.kind === "queued" && state.nearby ? 1_000 + turn : turn };
  }).sort((a, b) => a.turn - b.turn || a.index - b.index);
  for (const { row } of order) {
    // Rows a walk queued wait while the switch is off; ones Mike asked for don't.
    if (!asked(row)?.manual && !autoOn()) continue;
    const held = daily + reserved + caps.perRun > caps.daily ? "daily cap"
      : monthly + reserved + caps.perRun > caps.monthly ? "monthly cap" : undefined;
    if (held !== undefined) pass.held.set(row.osmId, held);
    if (held !== undefined || slots <= 0) continue;
    const failure = begin ? await begin(row) : null;
    if (failure !== null) {
      pass.failed.set(row.osmId, failure);
      continue;
    }
    pass.started.push(row.osmId);
    reserved += caps.perRun;
    slots--;
  }
  return pass;
}

/** Starts whatever can start now, and says what it did. */
export async function startQueued(ctx: MutationCtx): Promise<QueuePass> {
  return await passQueue(ctx, (row) => begin(ctx, row));
}

/**
 * Starts a queued place's run, or restarts its journal for lore:resume, as a new budget
 * segment. The workflow starts first, as the machine's state needs its id; a refusal
 * throws, so the workflow's start rolls back with it. Returns why a resume couldn't
 * start, or null.
 */
async function begin(ctx: MutationCtx, row: Doc<"lorePlaces">): Promise<string | null> {
  if (row.state.kind !== "queued") throw new Error(`lore: ${row.osmId} isn't queued`);
  const step = row.state.resume;
  if (step !== undefined) {
    const journal = await journalOf(ctx, row);
    try {
      if (journal === null) throw new Error("its journal has been deleted");
      await restart(ctx, components.workflow, journal.workflowId as never, { from: step, startAsync: true });
    } catch (error) {
      const why = `Couldn't resume: ${String(error).slice(0, 400)}`;
      await lorePlace.send(ctx, row._id, { type: "RESUME_FAILED", error: why });
      return why;
    }
    await started(await lorePlace.send(ctx, row._id, { type: "RESUMED", workflowId: journal.workflowId }));
    // The journal is the run's again until it finishes.
    await ctx.db.delete("loreJournals", journal._id);
    return null;
  }
  const run = row.attempts + 1;
  // The last run's journal won't be resumed now that there's a new run.
  for (const journal of await ctx.db.query("loreJournals").withIndex("by_osm", (q) => q.eq("osmId", row.osmId)).collect()) {
    await ctx.scheduler.runAfter(0, internal.lore.cleanUpRun, { osmId: row.osmId, run: journal.run, workflowId: journal.workflowId });
    await ctx.db.delete("loreJournals", journal._id);
  }
  const workflowId = await workflow.start(ctx, internal.lorePipeline.run, { osmId: row.osmId, run }, {
    onComplete: internal.lore.runFinished, context: { osmId: row.osmId, run },
  });
  await started(await lorePlace.send(ctx, row._id, { type: "START", workflowId }));
  return null;
}

function started(result: Awaited<ReturnType<typeof lorePlace.send>>) {
  if (result.status !== "done") throw new Error(`lore: the place refused to start (${result.code}): ${result.reasons.join(" ")}`);
}

/**
 * When a run (or a resume of one) ends. A successful one has already published itself
 * (loreRun.publish); one that failed, or finished without publishing, fails now, unless
 * its place has moved on to another run, which refuses it. Either way its research
 * threads are deleted now, and its journal is kept for `journalKeep` in case it's resumed.
 */
export const runFinished = internalMutation({
  args: { workflowId: vWorkflowId, result: vResultValidator, context: v.object({ osmId: v.number(), run: v.number() }) },
  returns: v.null(),
  handler: async (ctx, { workflowId, result, context: { osmId, run } }) => {
    const row = await placeRow(ctx, osmId);
    if (row !== null) {
      if (result.kind !== "success") {
        const error = result.kind === "failed" ? result.error : "Cancelled";
        // Refused if the place has moved on to another run: a stale report changes nothing.
        await lorePlace.send(ctx, row._id, { type: "RUN_FAILED", run, error });
      } else if (row.attempts === run && row.state.kind === "researching") {
        await lorePlace.send(ctx, row._id, { type: "RUN_FAILED", run, error: "The run finished without publishing." });
      }
      const after = (await ctx.db.get("lorePlaces", row._id))!;
      if (after.attempts === run && after.state.kind !== "queued" && after.state.kind !== "researching") {
        await ctx.db.insert("loreJournals", { osmId, run, workflowId, until: Date.now() + journalKeep });
        await ctx.scheduler.runAfter(0, internal.lore.cleanUpRun, { osmId, run });
      }
    }
    await startQueued(ctx);
    return null;
  },
});

/** Deletes a run's research threads (every page its agents read), and its journal when given. */
export const cleanUpRun = internalMutation({
  args: { osmId: v.number(), run: v.number(), workflowId: v.optional(v.string()) }, returns: v.null(),
  handler: async (ctx, { osmId, run, workflowId }) => {
    const threads = await ctx.db.query("loreThreads").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
    for (const thread of threads) {
      await ctx.runMutation(components.agent.threads.deleteAllForThreadIdAsync, { threadId: thread.threadId });
      await ctx.db.delete("loreThreads", thread._id);
    }
    if (workflowId) await workflow.cleanup(ctx, workflowId as never);
    return null;
  },
});

/**
 * Hourly (crons.ts): holds on calls that never came back are kept as spent, old
 * journals and request records go, and anything a cap held starts once the day or
 * month rolls over. The retries and the queue's expiry are the machine's own timers.
 */
export const tick = internalMutation({
  args: {}, returns: v.null(),
  handler: async (ctx) => {
    const now = Date.now();
    await releaseStale(ctx);
    for (const journal of await ctx.db.query("loreJournals").withIndex("by_until", (q) => q.lte("until", now)).take(50)) {
      const place = await placeRow(ctx, journal.osmId);
      // A place on its way to a run: a resume may need it, and a new run deletes it anyway.
      if (place?.state.kind === "queued" || place?.state.kind === "researching") continue;
      await workflow.cleanup(ctx, journal.workflowId as never);
      await ctx.db.delete("loreJournals", journal._id);
    }
    // The per-person limits only look back a month.
    for (const old of await ctx.db.query("loreRequests").withIndex("by_at", (q) => q.lt("at", now - 62 * day)).take(200)) {
      await ctx.db.delete("loreRequests", old._id);
    }
    await machines.pruneHistory(ctx, { before: now - historyKeep });
    // In its own transaction: it reads Convex's record of scheduled functions.
    await ctx.scheduler.runAfter(0, internal.lore.checkTimers, {});
    await startQueued(ctx);
    return null;
  },
});

/** The machines' history (lore:history) is kept this long. */
const historyKeep = 180 * day;

/** Logs any of the machines' timers whose step threw, which stay pending until machines:rearmTimer. */
export const checkTimers = internalMutation({
  args: {}, returns: v.number(),
  handler: async (ctx) => {
    const failed = await machines.failedTimers(ctx, { limit: 20 });
    if (failed.length > 0) console.error(`lore: ${failed.length} machine timers failed. npx convex run machines:failedTimers`, failed);
    return failed.length;
  },
});

/** Forgets whose walk queued places that haven't finished, for account deletion. Returns how many it went through. */
export const forgetRequester = internalMutation({
  args: { userId: v.id("users"), limit: v.number() }, returns: v.number(),
  handler: async (ctx, { userId, limit }) => {
    const rows = await ctx.db.query("lorePlaces").withIndex("by_requester", (q) => q.eq("state.requestedBy", userId)).take(limit);
    for (const row of rows) await lorePlace.send(ctx, row._id, { type: "FORGET_REQUESTER" });
    return rows.length;
  },
});

/**
 * Researches a place now, for trying the pipeline or redoing one. Skips the walked
 * and bundled checks and the LORE_AUTO switch, but not the caps.
 * `npx convex run lore:research '{"osmId": 11688696}'`
 */
export const research = internalAction({
  args: { osmId: v.number() },
  returns: v.string(),
  handler: async (ctx, { osmId }): Promise<string> => {
    return await ctx.runMutation(internal.lore.queueManual, { osmId });
  },
});

export const queueManual = internalMutation({
  args: { osmId: v.number() },
  returns: v.string(),
  handler: async (ctx, { osmId }) => {
    if (!Number.isSafeInteger(osmId) || osmId <= 0) throw new ConvexError("Invalid OSM relation id");
    const row = await placeRow(ctx, osmId);
    if (row?.state.kind === "researching") return "already researching";
    await queue(ctx, osmId, row?.name ?? "", { manual: true });
    return queueAnswer(await startQueued(ctx), osmId, "started");
  },
});

/** What lore:research and lore:resume say about the place they queued. */
function queueAnswer(pass: QueuePass, osmId: number, started: string) {
  if (pass.started.includes(osmId)) return started;
  const failed = pass.failed.get(osmId);
  if (failed) return failed;
  const held = pass.held.get(osmId);
  return `queued${held ? ` (held by the ${held})` : ""}`;
}

/** Whether a run's journal has a step called `name`, the way restart looks for it. */
async function hasStep(ctx: MutationCtx, workflowId: string, name: string): Promise<boolean> {
  let cursor: string | null = null;
  for (let page = 0; page < 20; page++) {
    const steps = await workflow.listSteps(ctx, workflowId as never, { paginationOpts: { cursor, numItems: 100 } });
    if (steps.page.some((step) => step.name === name)) return true;
    if (steps.isDone) return false;
    cursor = steps.continueCursor;
  }
  return false;
}

/**
 * Runs a finished run again from one of its steps, keeping what the steps before it
 * found and paid for: after a step broke on a bug, a later step has changed, or the
 * run ran out of money. `from` names the step, like "lorePipeline:write" (see
 * lorePipeline.run); "stickers" draws the stickers a run couldn't. It queues like a
 * new run, so it waits for a free slot and the caps, and gets a new budget segment of
 * its own caps.perRun. Secrets dropped for reasons that weren't theirs come back.
 * `npx convex run lore:resume '{"osmId": 11688696, "from": "lorePipeline:write"}'`
 */
export const resume = internalMutation({
  args: { osmId: v.number(), from: v.string() },
  returns: v.string(),
  handler: async (ctx, { osmId, from }) => {
    const row = await placeRow(ctx, osmId);
    const finished = ["ready", "quiet", "failed", "quietWaiting", "failedWaiting"];
    if (row === null || !finished.includes(row.state.kind)) throw new ConvexError("Only a finished run can be resumed");
    const journal = await journalOf(ctx, row);
    if (journal === null) throw new ConvexError("This run's journal has been deleted, so it can't be resumed. Start a new run with lore:research.");
    // Checked now, so a typo is an error here rather than a failed restart in the queue.
    if (!await hasStep(ctx, journal.workflowId, from)) throw new ConvexError(`This run's journal has no step called "${from}"`);
    const result = await lorePlace.send(ctx, row._id, { type: "RESUME", from });
    if (result.status !== "done") throw new ConvexError(result.reasons.join(" "));
    return queueAnswer(await startQueued(ctx), osmId, "resumed");
  },
});

/**
 * Reads one page the way research and the quote check do, without the model: what it
 * got, or why it refused. `npx convex run lore:readPage '{"url": "https://..."}'`
 */
export const readPage = internalAction({
  args: { url: v.string() },
  returns: v.object({ ok: v.boolean(), url: v.string(), title: v.optional(v.string()), chars: v.optional(v.number()), start: v.optional(v.string()), reason: v.optional(v.string()) }),
  handler: async (_ctx, { url }) => {
    const page = await fetchPage(url);
    return page.ok ? { ok: true, url: page.url, title: page.title, chars: page.text.length, start: page.text.slice(0, 300) } : { ok: false, url: page.url, reason: page.reason };
  },
});

/**
 * What the OpenRouter key has used and has left, in US dollars, from OpenRouter
 * itself. Its limit, set on openrouter.ai, is the backstop behind the caps.
 * `npx convex run lore:credits`
 */
export const credits = internalAction({
  args: {},
  returns: v.object({ limit: v.union(v.number(), v.null()), used: v.number(), remaining: v.union(v.number(), v.null()) }),
  handler: async () => {
    const apiKey = env.OPENROUTER_API_KEY;
    if (!apiKey) throw new ConvexError("OPENROUTER_API_KEY isn't set");
    const response = await fetch("https://openrouter.ai/api/v1/key", { headers: { Authorization: `Bearer ${apiKey}` } });
    if (!response.ok) throw new ConvexError(`OpenRouter answered ${response.status}`);
    const { data } = await response.json() as { data: { limit: number | null; usage: number; limit_remaining: number | null } };
    return { limit: data.limit, used: data.usage, remaining: data.limit_remaining };
  },
});

// Review. Stories about First Nations heritage, deaths or crime, and living people
// wait as "pending" until Mike approves them; anything can be hidden later.

const vReviewEntry = v.object({
  entryId: v.string(), osmId: v.number(), suburb: v.string(), title: v.string(), body: v.string(), category: v.string(),
  place: v.optional(vPlace), sources: v.array(v.string()), sensitive: v.array(v.string()),
  review: vLoreReview, droppedBy: v.optional(v.string()), checkNotes: v.array(v.string()),
  claims: v.array(v.object({ text: v.string(), url: v.string(), quote: v.string(), found: v.optional(v.boolean()) })),
  stickerUrl: v.union(v.string(), v.null()),
});

async function forReview(ctx: QueryCtx, entry: Doc<"loreEntries">) {
  return {
    entryId: entry.entryId, osmId: entry.osmId, suburb: entry.suburb, title: entry.title, body: entry.body, category: entry.category,
    ...(entry.place ? { place: entry.place } : {}), sources: entry.sources, sensitive: entry.sensitive,
    review: entry.state.kind, ...(entry.state.kind === "dropped" ? { droppedBy: entry.state.by } : {}), checkNotes: entry.checkNotes,
    claims: entry.claims.map(({ text, url, quote, found }) => ({ text, url, quote, ...(found === undefined ? {} : { found }) })),
    stickerUrl: entry.stickerFile ? await ctx.storage.getUrl(entry.stickerFile) : null,
  };
}

/** Secrets waiting for Mike. `npx convex run lore:pending` */
export const pending = internalQuery({
  args: {}, returns: v.array(vReviewEntry),
  handler: async (ctx) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_review", (q) => q.eq("state.kind", "pending")).collect();
    return await Promise.all(rows.map((entry) => forReview(ctx, entry)));
  },
});

/** Every secret a place's runs wrote, dropped ones too, with what each check said.
 * `npx convex run lore:entries '{"osmId": 11688696}'` */
export const entries = internalQuery({
  args: { osmId: v.number(), run: v.optional(v.number()) }, returns: v.array(vReviewEntry),
  handler: async (ctx, { osmId, run }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => run === undefined ? q.eq("osmId", osmId) : q.eq("osmId", osmId).eq("run", run)).collect();
    return await Promise.all(rows.map((entry) => forReview(ctx, entry)));
  },
});

/** Mike's review of one secret: APPROVE or HIDE. One that's already there is left be. */
async function setReview(ctx: MutationCtx, entryId: string, review: "approved" | "hidden") {
  const entry = await ctx.db.query("loreEntries").withIndex("by_entry", (q) => q.eq("entryId", entryId)).unique();
  if (entry === null) throw new ConvexError("No secret with that id");
  if (entry.state.kind === review) return null;
  const result = await loreEntry.send(ctx, entry._id, { type: review === "approved" ? "APPROVE" : "HIDE" });
  if (result.status !== "done") throw new ConvexError(`That secret is ${entry.state.kind}, not up for review`);
  return null;
}

/** Puts a pending (or hidden) secret live. `npx convex run lore:approve '{"entryId": "osm123-..."}'` */
export const approve = internalMutation({
  args: { entryId: v.string() }, returns: v.null(),
  handler: async (ctx, { entryId }) => await setReview(ctx, entryId, "approved"),
});

/** Takes a secret down, wherever it was. `npx convex run lore:hide '{"entryId": "osm123-..."}'` */
export const hide = internalMutation({
  args: { entryId: v.string() }, returns: v.null(),
  handler: async (ctx, { entryId }) => await setReview(ctx, entryId, "hidden"),
});

// The same review from the iPhone's Settings, for Chef's admin (Mike) only.

/** Whoever's signed in is Chef's admin, by the same role its own admin panel checks
 * (chef.ts, `amAdmin`). Asks the component directly, so this file (which sync.ts
 * loads) doesn't pull in the rest of the package. */
async function isAdmin(ctx: QueryCtx) {
  const userId = await currentUserId(ctx);
  if (userId === null) return false;
  const user = await ctx.runQuery(components.feedback.users.get, { userId });
  return user?.role === "admin";
}

async function requireAdmin(ctx: QueryCtx) {
  if (!await isAdmin(ctx)) throw new ConvexError("Only the admin can review secrets");
}

/** Secrets waiting for the admin, in the order they were written. Null for anyone
 * else, so the app knows not to show the list at all. */
export const adminPending = query({
  args: {}, returns: v.union(v.null(), v.array(vReviewEntry)),
  handler: async (ctx) => {
    if (!await isAdmin(ctx)) return null;
    const rows = await ctx.db.query("loreEntries").withIndex("by_review", (q) => q.eq("state.kind", "pending")).collect();
    return await Promise.all(rows.map((entry) => forReview(ctx, entry)));
  },
});

// The admin check asks the feedback component, which a machine's guard can't, so it
// happens here, and the review itself is lore:approve or lore:hide, which send the
// machine's server events.

/** lore:approve, for the admin from the app. */
export const adminApprove = mutation({
  args: { entryId: v.string() }, returns: v.null(),
  handler: async (ctx, { entryId }): Promise<null> => {
    await requireAdmin(ctx);
    return await ctx.runMutation(internal.lore.approve, { entryId });
  },
});

/** lore:hide, for the admin from the app. */
export const adminHide = mutation({
  args: { entryId: v.string() }, returns: v.null(),
  handler: async (ctx, { entryId }): Promise<null> => {
    await requireAdmin(ctx);
    return await ctx.runMutation(internal.lore.hide, { entryId });
  },
});

/** Every researched place with its spend, and the totals the caps look at.
 * `npx convex run lore:status` */
export const status = internalQuery({
  args: {},
  returns: v.object({
    today: v.number(), month: v.number(), auto: v.boolean(),
    places: v.array(v.object({
      osmId: v.number(), name: v.string(), status: v.string(), attempts: v.number(), cost: v.number(), runCost: v.number(),
      held: v.optional(v.string()), error: v.optional(v.string()), startedAt: v.optional(v.number()), finishedAt: v.optional(v.number()),
      retryAt: v.optional(v.number()), live: v.number(), pending: v.number(),
    })),
  }),
  handler: async (ctx) => {
    const today = dayKey(Date.now());
    const rows = await ctx.db.query("lorePlaces").collect();
    // What the queue would do now, without starting anything.
    const { held } = await passQueue(ctx);
    return {
      today: await spentBetween(ctx, today, today),
      month: await spentBetween(ctx, ...monthOf(today)),
      auto: autoOn(),
      places: await Promise.all(rows.map(async (row) => {
        const state = row.state;
        const why = held.get(row.osmId);
        return {
          osmId: row.osmId, name: row.name, status: state.kind, attempts: row.attempts, cost: row.cost, runCost: row.runCost,
          ...(why ? { held: why } : {}), ...("error" in state ? { error: state.error } : {}),
          ...("startedAt" in state ? { startedAt: state.startedAt } : {}),
          ...("finishedAt" in state ? { finishedAt: state.finishedAt } : {}),
          ...("retryAt" in state ? { retryAt: state.retryAt } : {}),
          live: (await withReview(ctx, row.osmId, "auto")).length + (await withReview(ctx, row.osmId, "approved")).length,
          pending: (await withReview(ctx, row.osmId, "pending")).length,
        };
      })),
    };
  },
});

/** How many places and secrets are in each state, and any timers that failed.
 * `npx convex run lore:machines` */
const machineCounts = internalQuery({
  args: {},
  returns: v.object({
    places: v.record(v.string(), v.number()),
    entries: v.record(v.string(), v.number()),
    failedTimers: v.array(v.object({ machine: v.string(), id: v.string(), event: v.string(), dueAt: v.number() })),
  }),
  handler: async (ctx) => {
    const count = (rows: { state: { kind: string } }[]) => {
      const counts: Record<string, number> = {};
      for (const row of rows) counts[row.state.kind] = (counts[row.state.kind] ?? 0) + 1;
      return counts;
    };
    return {
      places: count(await ctx.db.query("lorePlaces").collect()),
      entries: count(await ctx.db.query("loreEntries").collect()),
      failedTimers: await machines.failedTimers(ctx, { limit: 50 }),
    };
  },
});

// Named `machines` for `npx convex run`; the catalog has that name in this file.
export { machineCounts as machines };

/** A place's research, step by step, from the machine's history: every event, who sent
 * it, and why one was refused. `npx convex run lore:history '{"osmId": 11688696}'` */
export const history = internalQuery({
  args: { osmId: v.number(), paginationOpts: v.optional(paginationOptsValidator) },
  returns: v.object({ page: vHistory, isDone: v.boolean(), continueCursor: v.string() }),
  handler: async (ctx, { osmId, paginationOpts }) => {
    const row = await placeRow(ctx, osmId);
    if (row === null) throw new ConvexError("No lore place with that OSM relation");
    const { page, isDone, continueCursor } = await lorePlace.history(ctx, row._id, { paginationOpts: paginationOpts ?? { numItems: 200, cursor: null } });
    return { page, isDone, continueCursor };
  },
});

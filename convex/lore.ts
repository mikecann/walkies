// Secrets for new suburbs, server side. What the phones ask for (forPlace), what
// starts research (a walk in a place that has none), the queue that keeps runs inside
// the spending caps, and Mike's review. The run itself is lorePipeline.ts, and the
// contract the apps build against is shared/lore-api.md.
import { ConvexError, v } from "convex/values";
import { restart, vResultValidator, vWorkflowId, WorkflowManager } from "@convex-dev/workflow";
import { components, internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import {
  env, internalAction, internalMutation, internalQuery, mutation, query, type ActionCtx, type MutationCtx, type QueryCtx,
} from "./_generated/server";
import { overBudget } from "./loreBudget";
import { boundaryArea, boundingBox, fetchPage, insideBoundary } from "./loreChecks";
import {
  bundledOsmIds, caps, checksPerUserPerDay, day, failedRetry, journalKeep, maxAttempts, maxRunning, minWalkedTiles, queueExpiry,
  suburbArea, suburbsPerUserPerDay, suburbsPerUserPerMonth, walkCheck,
} from "./loreConfig";
import { bumpVersion, dayKey, deleteSticker, monthOf, placeRow, releaseStale, spentBetween } from "./loreRun";
import { boundaryFromNominatim, type PlaceData } from "./placeData";
import { nominatim } from "./places";
import { vLoreReview } from "./schema";
import { currentUserId } from "./users";

/**
 * Runs lorePipeline.run: two runs of three research angles at once, plus room for
 * stickers. It lives here rather than in lorePipeline.ts so that sync.ts, which imports
 * this file, doesn't load the AI libraries on every sync.
 */
export const workflow = new WorkflowManager(components.workflow, { workpoolOptions: { maxParallelism: 6 } });

/** The switch. Off unless LORE_AUTO is exactly "1", so prod never starts a paid run by itself. */
export const autoOn = () => env.LORE_AUTO === "1";

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
      status: row.status,
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

async function withReview(ctx: QueryCtx, osmId: number, review: Doc<"loreEntries">["review"]) {
  return await ctx.db.query("loreEntries").withIndex("by_osm_review", (q) => q.eq("osmId", osmId).eq("review", review)).collect();
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
export async function noticePlace(ctx: MutationCtx, place: Doc<"places">) {
  if (!autoOn()) return;
  if (place.osmId !== undefined && (bundledOsmIds.has(place.osmId) || place.loreNoSuburb || await placeRow(ctx, place.osmId) !== null)) return;
  await ctx.scheduler.runAfter(0, internal.lore.readPlace, { placeId: place._id });
}

/** Places a walk can get looked at, so a long list doesn't start a burst of checks. */
const placesPerWalk = 10;

/**
 * Called by sync:saveWalk for a new walk. The phones upload places before walks, so a
 * person's first walk arrives after the place it was in was turned down for having no
 * walk; this looks at their places again now there is one.
 */
export async function noticeWalk(ctx: MutationCtx, userId: Id<"users">, walkId: Id<"walks">) {
  if (!autoOn()) return;
  const places = await ctx.db.query("places").withIndex("by_user_client", (q) => q.eq("userId", userId)).collect();
  let looked = 0;
  for (const place of places) {
    if (looked >= placesPerWalk) break;
    if (place.walkedTiles !== undefined && place.walkedTiles < minWalkedTiles) continue;
    if (place.osmId !== undefined && (bundledOsmIds.has(place.osmId) || place.loreNoSuburb || await placeRow(ctx, place.osmId) !== null)) continue;
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

/** Whether one of the person's newest walks has good GPS fixes inside the boundary. */
async function walkedInside(ctx: ActionCtx, userId: Id<"users">, boundary: Boundary, walkId?: Id<"walks">): Promise<boolean> {
  const box = boundingBox(boundary);
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
  if (await placeRow(ctx, osmId) !== null) return "known";
  if (place?.loreNoSuburb && place.osmId === osmId) return "not a suburb";
  if (walkedTiles < minWalkedTiles) return "not walked";
  // Past either limit nothing is saved, so a sync after it resets tries again.
  const since = dayAndMonthStart(Date.now());
  const started = await ctx.db.query("loreRequests").withIndex("by_user_at", (q) => q.eq("userId", userId).gte("at", since.month)).collect();
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
    await queue(ctx, osmId, name, { requestedBy: userId });
    await startQueued(ctx);
    return "queued";
  },
});

async function queue(ctx: MutationCtx, osmId: number, name: string, { manual, requestedBy }: { manual?: boolean; requestedBy?: Id<"users"> } = {}) {
  const row = await placeRow(ctx, osmId);
  const now = Date.now();
  const who = { ...(manual ? { manual } : {}), ...(requestedBy ? { requestedBy } : {}) };
  if (row === null) {
    await ctx.db.insert("lorePlaces", { osmId, name, status: "queued", version: 0, attempts: 0, queuedAt: now, cost: 0, runCost: 0, segment: 0, ...who });
  } else {
    await ctx.db.patch("lorePlaces", row._id, {
      status: "queued", queuedAt: now, retryAt: undefined, held: undefined, ...who,
      ...(row.status === "ready" || row.status === "quiet" || row.status === "failed" ? { requeuedFrom: row.status } : {}),
    });
  }
}

// The queue. A run starts when a slot's free and it can't take today's or this
// month's spending over its cap, even if every run going spends its whole limit
// (which the holds on every call make the most it can spend). It takes turns between
// people: Mike's own asks first, then everyone's oldest before anyone's second.

/** Starts whatever can start now. Returns how many did. */
export async function startQueued(ctx: MutationCtx): Promise<number> {
  const running = await ctx.db.query("lorePlaces").withIndex("by_status", (q) => q.eq("status", "researching")).collect();
  const queued = await ctx.db.query("lorePlaces").withIndex("by_status", (q) => q.eq("status", "queued")).collect();
  if (queued.length === 0) return 0;
  const now = Date.now();
  const today = dayKey(now);
  const daily = await spentBetween(ctx, today, today);
  const monthly = await spentBetween(ctx, ...monthOf(today));
  // What the runs going now could still spend before their own limit stops them.
  let reserved = running.reduce((sum, row) => sum + Math.max(0, caps.perRun - row.runCost), 0);
  let slots = maxRunning - running.length;
  const turns = new Map<string, number>();
  for (const row of running) if (row.requestedBy) turns.set(row.requestedBy, (turns.get(row.requestedBy) ?? 0) + 1);
  const order = queued.map((row, index) => {
    // A retry nobody asked for takes its own turn.
    const who = row.requestedBy ?? row._id;
    const turn = turns.get(who) ?? 0;
    turns.set(who, turn + 1);
    return { row, index, turn: row.manual ? -1 : turn };
  }).sort((a, b) => a.turn - b.turn || a.index - b.index);
  let started = 0;
  for (const { row } of order) {
    // Rows a walk queued wait while the switch is off; ones Mike asked for don't.
    if (!row.manual && !autoOn()) continue;
    const held = daily + reserved + caps.perRun > caps.daily ? "daily cap"
      : monthly + reserved + caps.perRun > caps.monthly ? "monthly cap" : undefined;
    if (held !== undefined || slots <= 0) {
      if (row.held !== held) await ctx.db.patch("lorePlaces", row._id, { held });
      continue;
    }
    if (!await begin(ctx, row, now)) continue;
    reserved += caps.perRun;
    slots--;
    started++;
  }
  return started;
}

/** Starts a queued row's run, or restarts its journal for lore:resume, as a new budget segment. */
async function begin(ctx: MutationCtx, row: Doc<"lorePlaces">, now: number): Promise<boolean> {
  const fresh = { status: "researching" as const, held: undefined, startedAt: now, finishedAt: undefined, runCost: 0, segment: (row.segment ?? 0) + 1, error: undefined, journalUntil: undefined };
  if (row.resumeFrom !== undefined && row.workflowId !== undefined) {
    try {
      await restart(ctx, components.workflow, row.workflowId as never, { from: row.resumeFrom, startAsync: true });
    } catch (error) {
      await ctx.db.patch("lorePlaces", row._id, {
        status: row.requeuedFrom ?? "failed", error: `Couldn't resume: ${String(error).slice(0, 400)}`, resumeFrom: undefined, manual: undefined, held: undefined,
      });
      return false;
    }
    await ctx.db.patch("lorePlaces", row._id, { ...fresh, resumeFrom: undefined });
    return true;
  }
  const run = row.attempts + 1;
  // The last run's journal won't be resumed now that there's a new run.
  if (row.workflowId) await ctx.scheduler.runAfter(0, internal.lore.cleanUpRun, { osmId: row.osmId, run: row.attempts, workflowId: row.workflowId });
  await ctx.db.patch("lorePlaces", row._id, { ...fresh, attempts: run, requeuedFrom: undefined, resumeFrom: undefined });
  const workflowId = await workflow.start(ctx, internal.lorePipeline.run, { osmId: row.osmId, run }, {
    onComplete: internal.lore.runFinished, context: { osmId: row.osmId, run },
  });
  await ctx.db.patch("lorePlaces", row._id, { workflowId });
  return true;
}

/** Secrets the checks dropped for reasons that weren't theirs, which lore:resume brings back. */
const notTheirFault = ["run stopped", "budget", "not checked"];

/**
 * When a run (or a resume of one) ends. A successful one has already published itself
 * (loreRun.publish). Either way its research threads are deleted now, and its journal
 * is kept for `journalKeep` in case it's resumed.
 */
export const runFinished = internalMutation({
  args: { workflowId: vWorkflowId, result: vResultValidator, context: v.object({ osmId: v.number(), run: v.number() }) },
  returns: v.null(),
  handler: async (ctx, { result, context: { osmId, run } }) => {
    const row = await placeRow(ctx, osmId);
    if (row !== null && row.status === "researching" && row.attempts === run) {
      const now = Date.now();
      // A manual run's retries respect LORE_AUTO like any other.
      const done = { manual: undefined, requestedBy: undefined, journalUntil: now + journalKeep };
      if (result.kind === "success") {
        await ctx.db.patch("lorePlaces", row._id, done);
      } else {
        const error = result.kind === "failed" ? result.error : "Cancelled";
        // A run stopped at its spending limit would only spend it again, so Mike decides.
        const retry = !error.includes(overBudget) && row.attempts < maxAttempts;
        await ctx.db.patch("lorePlaces", row._id, {
          ...done, status: "failed", error: error.slice(0, 500), finishedAt: now, retryAt: retry ? now + failedRetry : undefined,
        });
        const unfinished = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
        for (const entry of unfinished.filter((e) => e.review === "checking")) {
          await deleteSticker(ctx, entry);
          await ctx.db.patch("loreEntries", entry._id, {
            review: "dropped", droppedBy: "run stopped", stickerFile: undefined, checkNotes: [...entry.checkNotes, "The run stopped before it finished."],
          });
        }
      }
      await ctx.scheduler.runAfter(0, internal.lore.cleanUpRun, { osmId, run });
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
 * Hourly (crons.ts): quiet and failed places due another look go back on the queue,
 * places a walk queued that haven't started in `queueExpiry` leave it, holds on calls
 * that never came back are kept as spent, old journals and request records go, and
 * anything a cap held starts once the day or month rolls over.
 */
export const tick = internalMutation({
  args: {}, returns: v.null(),
  handler: async (ctx) => {
    const now = Date.now();
    if (autoOn()) {
      const due = await ctx.db.query("lorePlaces").withIndex("by_retry", (q) => q.gte("retryAt", 0).lte("retryAt", now)).collect();
      for (const row of due) await queue(ctx, row.osmId, row.name);
    }
    const waited = await ctx.db.query("lorePlaces").withIndex("by_status", (q) => q.eq("status", "queued").lt("queuedAt", now - queueExpiry)).collect();
    for (const row of waited.filter((r) => !r.manual)) {
      // Never researched: it's as if nobody had walked there, so the next walk can queue it.
      if (row.attempts === 0) await ctx.db.delete("lorePlaces", row._id);
      else await ctx.db.patch("lorePlaces", row._id, { status: row.requeuedFrom ?? "failed", requeuedFrom: undefined, requestedBy: undefined, held: undefined });
    }
    await releaseStale(ctx);
    const journals = await ctx.db.query("lorePlaces").withIndex("by_journal", (q) => q.gte("journalUntil", 0).lte("journalUntil", now)).take(50);
    for (const row of journals) {
      if (row.status === "queued" || row.status === "researching") continue;
      if (row.workflowId) await workflow.cleanup(ctx, row.workflowId as never);
      await ctx.db.patch("lorePlaces", row._id, { workflowId: undefined, journalUntil: undefined });
    }
    // The per-person limits only look back a month.
    for (const old of await ctx.db.query("loreRequests").withIndex("by_at", (q) => q.lt("at", now - 62 * day)).take(200)) {
      await ctx.db.delete("loreRequests", old._id);
    }
    await startQueued(ctx);
    return null;
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
    if (row?.status === "researching") return "already researching";
    await queue(ctx, osmId, row?.name ?? "", { manual: true });
    const started = await startQueued(ctx);
    const after = await placeRow(ctx, osmId);
    return started > 0 && after?.status === "researching" ? "started" : `queued${after?.held ? ` (held by the ${after.held})` : ""}`;
  },
});

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
    if (row === null || row.status === "researching" || row.status === "queued") {
      throw new ConvexError("Only a finished run can be resumed");
    }
    if (row.workflowId === undefined) throw new ConvexError("This run's journal has been deleted, so it can't be resumed. Start a new run with lore:research.");
    // Checked now, so a typo is an error here rather than a failed restart in the queue.
    if (!await hasStep(ctx, row.workflowId, from)) throw new ConvexError(`This run's journal has no step called "${from}"`);
    const unfinished = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", row.attempts)).collect();
    for (const entry of unfinished.filter((e) => e.review === "dropped" && notTheirFault.includes(e.droppedBy ?? ""))) {
      await ctx.db.patch("loreEntries", entry._id, { review: "checking", droppedBy: undefined, checkNotes: [...entry.checkNotes, `Brought back by lore:resume from ${from}.`] });
    }
    await ctx.db.patch("lorePlaces", row._id, {
      status: "queued", queuedAt: Date.now(), resumeFrom: from, manual: true, requeuedFrom: row.status,
      held: undefined, error: undefined, retryAt: undefined,
    });
    await startQueued(ctx);
    const after = await placeRow(ctx, osmId);
    return after?.status === "researching" ? "resumed" : `queued${after?.held ? ` (held by the ${after.held})` : ""}`;
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
    review: entry.review, ...(entry.droppedBy ? { droppedBy: entry.droppedBy } : {}), checkNotes: entry.checkNotes,
    claims: entry.claims.map(({ text, url, quote, found }) => ({ text, url, quote, ...(found === undefined ? {} : { found }) })),
    stickerUrl: entry.stickerFile ? await ctx.storage.getUrl(entry.stickerFile) : null,
  };
}

/** Secrets waiting for Mike. `npx convex run lore:pending` */
export const pending = internalQuery({
  args: {}, returns: v.array(vReviewEntry),
  handler: async (ctx) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_review", (q) => q.eq("review", "pending")).collect();
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

async function setReview(ctx: MutationCtx, entryId: string, review: "approved" | "hidden") {
  const entry = await ctx.db.query("loreEntries").withIndex("by_entry", (q) => q.eq("entryId", entryId)).unique();
  if (entry === null) throw new ConvexError("No secret with that id");
  if (entry.review === "checking" || entry.review === "dropped") throw new ConvexError(`That secret is ${entry.review}, not up for review`);
  if (entry.review !== review) {
    // A hidden secret's art goes too. Approved again later, it shows a plain badge until
    // lore:resume from "stickers" draws it again.
    if (review === "hidden") await deleteSticker(ctx, entry);
    await ctx.db.patch("loreEntries", entry._id, { review, ...(review === "hidden" ? { stickerFile: undefined } : {}) });
    await bumpVersion(ctx, entry.osmId);
  }
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
    const rows = await ctx.db.query("loreEntries").withIndex("by_review", (q) => q.eq("review", "pending")).collect();
    return await Promise.all(rows.map((entry) => forReview(ctx, entry)));
  },
});

/** lore:approve, for the admin from the app. */
export const adminApprove = mutation({
  args: { entryId: v.string() }, returns: v.null(),
  handler: async (ctx, { entryId }) => {
    await requireAdmin(ctx);
    return await setReview(ctx, entryId, "approved");
  },
});

/** lore:hide, for the admin from the app. */
export const adminHide = mutation({
  args: { entryId: v.string() }, returns: v.null(),
  handler: async (ctx, { entryId }) => {
    await requireAdmin(ctx);
    return await setReview(ctx, entryId, "hidden");
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
      live: v.number(), pending: v.number(),
    })),
  }),
  handler: async (ctx) => {
    const today = dayKey(Date.now());
    const rows = await ctx.db.query("lorePlaces").collect();
    return {
      today: await spentBetween(ctx, today, today),
      month: await spentBetween(ctx, ...monthOf(today)),
      auto: autoOn(),
      places: await Promise.all(rows.map(async (row) => ({
        osmId: row.osmId, name: row.name, status: row.status, attempts: row.attempts, cost: row.cost, runCost: row.runCost,
        ...(row.held ? { held: row.held } : {}), ...(row.error ? { error: row.error } : {}),
        ...(row.startedAt ? { startedAt: row.startedAt } : {}), ...(row.finishedAt ? { finishedAt: row.finishedAt } : {}),
        live: (await withReview(ctx, row.osmId, "auto")).length + (await withReview(ctx, row.osmId, "approved")).length,
        pending: (await withReview(ctx, row.osmId, "pending")).length,
      }))),
    };
  },
});


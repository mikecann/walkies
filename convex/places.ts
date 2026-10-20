import { ConvexError, v } from "convex/values";
import { action, internalAction, internalMutation, internalQuery, type ActionCtx, type MutationCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { currentUserId } from "./users";
import { boundaryFromNominatim, walkableQuery, waysFromOverpass, type PlaceData } from "./placeData";

const version = 1;
const maxAge = 60 * 24 * 60 * 60 * 1000;
// Longer than Nominatim, the wait for the Overpass slot and both 135-second
// Overpass attempts. A crashed action cannot leave a place locked forever;
// completion also checks ownership.
const leaseDuration = 10 * 60 * 1000;
const requestSpacing = 1100;
// The warm queue's worker keeps a heartbeat on this sentinel row, so only one
// runs at a time. Overpass turns away callers that run several queries at once.
const workerId = -1;
// Every Overpass query, the worker's or someone opening a place, holds this slot
// while it runs. Longer than both 135-second attempts, so a crash frees it.
const overpassId = -2;
const overpassLease = 5 * 60 * 1000;
// Someone opening a place waits this long for the worker's query to finish, so
// the whole call stays inside the app's 6-minute timeout. The worker waits longer.
const overpassWait = 45_000;
const workerOverpassWait = 3 * 60 * 1000;
// Calls to places:get and places:warm, per user per minute.
const callsPerMinute = 30;
// A place that fails to warm is tried again after these waits, then left for
// places:get to fetch when someone actually opens it.
const retryDelays = [60_000, 5 * 60_000, 30 * 60_000];
const userAgent = "Walkies/0.1 (iOS walking app; https://github.com/mikecann/walkies)";
const endpoints = [
  "https://overpass-api.de/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];
type Cached = { url: string; fetchedAt: number };
type Claim = { kind: "ready"; file: Id<"_storage">; fetchedAt: number }
  | { kind: "busy" } | { kind: "fetch"; lease: number };

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const fresh = (row: Doc<"placeData">) => row.file !== undefined && row.version === version && Date.now() - row.fetchedAt < maxAge;
function validateId(osmId: number) {
  if (!Number.isSafeInteger(osmId) || osmId <= 0) throw new ConvexError("Invalid OSM relation id");
}
async function rowFor(ctx: MutationCtx, osmId: number) {
  return await ctx.db.query("placeData").withIndex("by_osm", (q) => q.eq("osmId", osmId)).unique();
}

async function claimPlace(ctx: MutationCtx, osmId: number, startAt = Date.now()): Promise<Claim> {
  validateId(osmId);
  const row = await rowFor(ctx, osmId);
  if (row && fresh(row)) return { kind: "ready", file: row.file!, fetchedAt: row.fetchedAt };
  if (row?.fetchingAt !== undefined && Date.now() - row.fetchingAt < leaseDuration) return { kind: "busy" };
  if (row) await ctx.db.patch("placeData", row._id, { fetchingAt: startAt });
  else await ctx.db.insert("placeData", { osmId, name: "", fetchedAt: 0, version, fetchingAt: startAt });
  return { kind: "fetch", lease: startAt };
}

/** Signed in, and not calling too often. Counts one call. */
export const allowCall = internalMutation({
  args: {}, returns: v.null(),
  handler: async (ctx) => {
    const userId = await currentUserId(ctx);
    if (userId === null) throw new ConvexError("Not signed in");
    const row = await ctx.db.query("placeCalls").withIndex("by_user", (q) => q.eq("userId", userId)).unique();
    const now = Date.now();
    const current = row !== null && now < row.windowStart + 60_000;
    if (current && row.count >= callsPerMinute) throw new ConvexError("Too many requests. Try again in a minute.");
    if (row === null) await ctx.db.insert("placeCalls", { userId, windowStart: now, count: 1 });
    else await ctx.db.patch("placeCalls", row._id, { windowStart: current ? row.windowStart : now, count: current ? row.count + 1 : 1 });
    return null;
  },
});

/** A cached place's street file, for scripts and fixtures.
 * `npx convex run places:cachedUrl '{"osmId": 11688696}'` */
export const cachedUrl = internalQuery({
  args: { osmId: v.number() }, returns: v.union(v.null(), v.string()),
  handler: async (ctx, { osmId }) => {
    const row = await ctx.db.query("placeData").withIndex("by_osm", (q) => q.eq("osmId", osmId)).unique();
    return row?.file ? await ctx.storage.getUrl(row.file) : null;
  },
});

export const claim = internalMutation({
  args: { osmId: v.number() },
  handler: async (ctx, { osmId }): Promise<Claim> => await claimPlace(ctx, osmId),
});

/** Ready files take one lookup. Another caller's in-flight fetch gets a brief wait. */
export const get = action({
  args: { osmId: v.number() },
  returns: v.object({ url: v.string(), fetchedAt: v.number() }),
  handler: async (ctx, { osmId }): Promise<Cached> => {
    await ctx.runMutation(internal.places.allowCall, {});
    for (let attempt = 0; attempt <= 20; attempt++) {
      const state = await ctx.runMutation(internal.places.claim, { osmId });
      if (state.kind === "ready") {
        const url = await ctx.storage.getUrl(state.file);
        if (!url) throw new ConvexError("Place data file is missing");
        return { url, fetchedAt: state.fetchedAt };
      }
      if (state.kind === "fetch") return await fetchPlace(ctx, osmId, state.lease, overpassWait);
      if (attempt < 20) await sleep(1000);
    }
    throw new ConvexError("This place is still getting ready");
  },
});

/** Queues places to warm. One worker fetches them one at a time, so a long list
 * never has several Overpass queries in flight at once. Repeated lists can't
 * queue a place twice. */
export const enqueue = internalMutation({
  args: { osmIds: v.array(v.number()) }, returns: v.null(),
  handler: async (ctx, { osmIds }) => {
    if (await currentUserId(ctx) === null) throw new ConvexError("Not signed in");
    if (osmIds.length > 100) throw new ConvexError("Too many places");
    const now = Date.now();
    for (const osmId of new Set(osmIds)) {
      validateId(osmId);
      const row = await rowFor(ctx, osmId);
      if (row && (fresh(row) || row.queuedAt !== undefined)) continue;
      if (row) await ctx.db.patch("placeData", row._id, { queuedAt: now, attempts: 0 });
      else await ctx.db.insert("placeData", { osmId, name: "", fetchedAt: 0, version, queuedAt: now, attempts: 0 });
    }
    await startWorker(ctx);
    return null;
  },
});

/** Puts every place without street data back on the warm queue, such as ones
 * that failed before the queue existed. `npx convex run places:requeueMissing --prod` */
export const requeueMissing = internalMutation({
  args: {}, returns: v.object({ queued: v.number() }),
  handler: async (ctx) => {
    const now = Date.now();
    let queued = 0;
    for (const row of await ctx.db.query("placeData").collect()) {
      if (row.osmId <= 0 || row.file !== undefined || row.queuedAt !== undefined) continue;
      await ctx.db.patch("placeData", row._id, { queuedAt: now, attempts: 0 });
      queued++;
    }
    if (queued > 0) await startWorker(ctx);
    return { queued };
  },
});

async function startWorker(ctx: MutationCtx) {
  const worker = await rowFor(ctx, workerId);
  const now = Date.now();
  if (worker?.fetchingAt !== undefined && now - worker.fetchingAt < leaseDuration) return;
  if (worker) await ctx.db.patch("placeData", worker._id, { fetchingAt: now });
  else await ctx.db.insert("placeData", { osmId: workerId, name: "Warm queue", fetchedAt: 0, version, fetchingAt: now });
  await ctx.scheduler.runAfter(0, internal.places.drain, {});
}

type Next = { kind: "fetch"; osmId: number; lease: number } | { kind: "wait"; ms: number } | { kind: "skip" } | { kind: "done" };

/** The worker's next step: the oldest place that's due, how long until one is, or done. */
export const claimNext = internalMutation({
  args: {},
  handler: async (ctx): Promise<Next> => {
    const now = Date.now();
    const worker = await rowFor(ctx, workerId);
    const row = await ctx.db.query("placeData").withIndex("by_queued", (q) => q.gte("queuedAt", 0)).first();
    if (!row) {
      if (worker) await ctx.db.patch("placeData", worker._id, { fetchingAt: undefined });
      return { kind: "done" };
    }
    if (row.queuedAt! > now) {
      // A heartbeat in the future keeps a second worker from starting while this one waits.
      if (worker) await ctx.db.patch("placeData", worker._id, { fetchingAt: row.queuedAt! });
      return { kind: "wait", ms: row.queuedAt! - now };
    }
    if (worker) await ctx.db.patch("placeData", worker._id, { fetchingAt: now });
    if (fresh(row)) {
      await ctx.db.patch("placeData", row._id, { queuedAt: undefined, attempts: undefined });
      return { kind: "skip" };
    }
    if (row.fetchingAt !== undefined && now - row.fetchingAt < leaseDuration) {
      // Someone opening this place is fetching it right now. Look again shortly.
      await ctx.db.patch("placeData", row._id, { queuedAt: now + 30_000 });
      return { kind: "skip" };
    }
    await ctx.db.patch("placeData", row._id, { queuedAt: undefined, fetchingAt: now });
    return { kind: "fetch", osmId: row.osmId, lease: now };
  },
});

export const drain = internalAction({
  args: {}, returns: v.null(),
  handler: async (ctx): Promise<null> => {
    const next = await ctx.runMutation(internal.places.claimNext, {});
    if (next.kind === "done") return null;
    if (next.kind === "fetch") {
      // finish() records a failure and queues the retry, so carry on to the next place.
      try { await fetchPlace(ctx, next.osmId, next.lease, workerOverpassWait); } catch { /* retried later */ }
    }
    await ctx.scheduler.runAfter(next.kind === "wait" ? next.ms : requestSpacing, internal.places.drain, {});
    return null;
  },
});

export const warm = action({
  args: { osmIds: v.array(v.number()) }, returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    await ctx.runMutation(internal.places.allowCall, {});
    return await ctx.runMutation(internal.places.enqueue, args);
  },
});

/** A sentinel (osmId 0) shares the Nominatim throttle across all users and jobs.
 * Check at execution time, since scheduled actions may start later than requested. */
export const nominatimSlot = internalMutation({
  args: {}, returns: v.number(),
  handler: async (ctx) => {
    const row = await rowFor(ctx, 0);
    const now = Date.now();
    const wait = row ? row.fetchedAt + requestSpacing - now : 0;
    if (wait > 0) return wait;
    if (row) await ctx.db.patch("placeData", row._id, { fetchedAt: now });
    else await ctx.db.insert("placeData", { osmId: 0, name: "Nominatim throttle", fetchedAt: now, version });
    return 0;
  },
});

/** Takes the Overpass slot, or says how long to wait before asking again. */
export const takeOverpass = internalMutation({
  args: { lease: v.number() }, returns: v.number(),
  handler: async (ctx, { lease }) => {
    const row = await rowFor(ctx, overpassId);
    const now = Date.now();
    if (row?.fetchingAt !== undefined && now - row.fetchingAt < overpassLease) return 500;
    if (row) await ctx.db.patch("placeData", row._id, { fetchingAt: lease });
    else await ctx.db.insert("placeData", { osmId: overpassId, name: "Overpass slot", fetchedAt: 0, version, fetchingAt: lease });
    return 0;
  },
});

export const releaseOverpass = internalMutation({
  args: { lease: v.number() }, returns: v.null(),
  handler: async (ctx, { lease }) => {
    const row = await rowFor(ctx, overpassId);
    if (row?.fetchingAt === lease) await ctx.db.patch("placeData", row._id, { fetchingAt: undefined });
    return null;
  },
});

export const finish = internalMutation({
  args: { osmId: v.number(), lease: v.number(), name: v.optional(v.string()), file: v.optional(v.id("_storage")), fetchedAt: v.optional(v.number()) },
  returns: v.boolean(),
  handler: async (ctx, { osmId, lease, name, file, fetchedAt }) => {
    const row = await rowFor(ctx, osmId);
    if (!row || row.fetchingAt !== lease) {
      if (file) await ctx.storage.delete(file);
      return false;
    }
    if (file) {
      await ctx.db.patch("placeData", row._id, {
        name: name ?? row.name, file, fetchedAt: fetchedAt ?? Date.now(), version,
        fetchingAt: undefined, queuedAt: undefined, attempts: undefined,
      });
      if (row.file) await ctx.storage.delete(row.file);
    } else {
      // Keep an older file on refresh failure, but allow the next call to retry.
      // Places the warm queue asked for go back on it after a wait, a few times.
      const attempts = row.attempts;
      const retry = attempts !== undefined && attempts < retryDelays.length;
      await ctx.db.patch("placeData", row._id, {
        fetchingAt: undefined,
        queuedAt: retry ? Date.now() + retryDelays[attempts] : undefined,
        attempts: retry ? attempts + 1 : undefined,
      });
    }
    return true;
  },
});

async function fetchJSON(url: string, timeout: number, init?: RequestInit): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(url, { ...init, headers: { "User-Agent": userAgent, "Accept-Language": "en", ...init?.headers }, signal: controller.signal });
    if (!response.ok) throw new Error(`OSM returned ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

/** Runs `query` while holding the Overpass slot, waiting up to `wait` for it. */
async function withOverpass<T>(ctx: ActionCtx, wait: number, query: () => Promise<T>): Promise<T> {
  const deadline = Date.now() + wait;
  let lease = Date.now();
  while (true) {
    const retry = await ctx.runMutation(internal.places.takeOverpass, { lease });
    if (retry === 0) break;
    if (Date.now() + retry > deadline) throw new Error("Overpass is busy");
    await sleep(retry);
    lease = Date.now();
  }
  try {
    return await query();
  } finally {
    await ctx.runMutation(internal.places.releaseOverpass, { lease });
  }
}

async function fetchPlace(ctx: ActionCtx, osmId: number, lease: number, overpassWait: number): Promise<Cached> {
  try {
    const deadline = Date.now() + 30_000;
    while (true) {
      const wait = await ctx.runMutation(internal.places.nominatimSlot, {});
      if (wait === 0) break;
      if (Date.now() + wait > deadline) throw new Error("Nominatim is busy");
      await sleep(wait);
    }
    const params = new URLSearchParams({ osm_ids: `R${osmId}`, format: "jsonv2", polygon_geojson: "1", polygon_threshold: "0.0001" });
    const { name, boundary } = boundaryFromNominatim(await fetchJSON(`https://nominatim.openstreetmap.org/lookup?${params}`, 15_000), osmId);
    const body = new URLSearchParams({ data: walkableQuery(boundary) }).toString();
    const ways = await withOverpass(ctx, overpassWait, async () => {
      let lastError: unknown;
      for (const endpoint of endpoints) {
        try {
          return waysFromOverpass(await fetchJSON(endpoint, 135_000, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body }));
        } catch (error) { lastError = error; }
      }
      throw lastError ?? new Error("No street data");
    });
    const file = await ctx.storage.store(new Blob([JSON.stringify({ boundary, ways } satisfies PlaceData)], { type: "application/json" }));
    const fetchedAt = Date.now();
    const saved = await ctx.runMutation(internal.places.finish, { osmId, lease, name, file, fetchedAt });
    if (!saved) throw new Error("Place fetch lease expired");
    const url = await ctx.storage.getUrl(file);
    if (!url) throw new Error("Place data file is missing");
    return { url, fetchedAt };
  } catch (error) {
    await ctx.runMutation(internal.places.finish, { osmId, lease });
    throw error;
  }
}

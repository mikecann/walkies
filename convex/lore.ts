// Secrets for new suburbs, server side. What the phones ask for (forPlace), what
// starts research (a walk in a place that has none), the queue that keeps runs inside
// the spending caps, and Mike's review. The run itself is lorePipeline.ts, and the
// contract the apps build against is shared/lore-api.md.
import { ConvexError, v } from "convex/values";
import { restart, vResultValidator, vWorkflowId, WorkflowManager } from "@convex-dev/workflow";
import { components, internal } from "./_generated/api";
import type { Doc } from "./_generated/dataModel";
import { env, internalAction, internalMutation, internalQuery, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { bundledOsmIds, caps, failedRetry, maxAttempts, maxRunning, minWalkedTiles, suburbsPerUserPerDay } from "./loreConfig";
import { bumpVersion, dayKey, overBudget, placeRow, spentBetween } from "./loreRun";
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
// saves the place: the city file has its OSM relation and the tiles they've walked.

/**
 * Called by sync:savePlace with the copy it kept. Reads the file in the background
 * unless this place has already been looked at, so most saves cost nothing.
 */
export async function noticePlace(ctx: MutationCtx, place: Doc<"places">) {
  if (!autoOn()) return;
  if (place.osmId !== undefined && (bundledOsmIds.has(place.osmId) || await placeRow(ctx, place.osmId) !== null)) return;
  await ctx.scheduler.runAfter(0, internal.lore.readPlace, { placeId: place._id });
}

export const placeFile = internalQuery({
  args: { placeId: v.id("places") },
  returns: v.union(v.null(), v.object({ userId: v.id("users"), file: v.id("_storage") })),
  handler: async (ctx, { placeId }) => {
    const place = await ctx.db.get("places", placeId);
    return place && { userId: place.userId, file: place.file };
  },
});

/** Finds a saved place's OSM relation and how many tiles have been walked in it. */
export const readPlace = internalAction({
  args: { placeId: v.id("places") },
  returns: v.null(),
  handler: async (ctx, { placeId }) => {
    const place = await ctx.runQuery(internal.lore.placeFile, { placeId });
    // Gone already: deleted, or replaced by a newer copy, which gets its own look.
    const blob = place && await ctx.storage.get(place.file);
    if (!place || !blob) return null;
    let city: { osmId?: unknown; name?: unknown; visited?: unknown };
    try {
      city = JSON.parse(await blob.text());
    } catch {
      return null;
    }
    const osmId = city.osmId;
    // Places drawn before they kept their relation, or found some other way, have none.
    if (typeof osmId !== "number" || !Number.isSafeInteger(osmId) || osmId <= 0) return null;
    await ctx.runMutation(internal.lore.noteWalked, {
      userId: place.userId, placeId, osmId,
      name: typeof city.name === "string" ? city.name : "",
      walkedTiles: Array.isArray(city.visited) ? city.visited.length : 0,
    });
    return null;
  },
});

/**
 * Queues research for a place someone has added and walked in, if nobody has yet.
 * Says what it did, for the tests and logs.
 */
export const noteWalked = internalMutation({
  args: { userId: v.id("users"), placeId: v.id("places"), osmId: v.number(), name: v.string(), walkedTiles: v.number() },
  returns: v.union(
    v.literal("off"), v.literal("bundled"), v.literal("known"), v.literal("not walked"), v.literal("too many"), v.literal("queued"),
  ),
  handler: async (ctx, { userId, placeId, osmId, name, walkedTiles }) => {
    const place = await ctx.db.get("places", placeId);
    if (place && place.osmId !== osmId) await ctx.db.patch("places", placeId, { osmId });
    if (!autoOn()) return "off";
    if (bundledOsmIds.has(osmId)) return "bundled";
    // Someone else got here first. Whatever state it's in, this walk pays nothing.
    if (await placeRow(ctx, osmId) !== null) return "known";
    const walked = await ctx.db.query("walks").withIndex("by_user_client", (q) => q.eq("userId", userId)).first();
    if (walked === null || walkedTiles < minWalkedTiles) return "not walked";
    // Past the limit, nothing is saved, so the next sync after today tries again.
    const now = Date.now();
    const calls = await ctx.db.query("loreCalls").withIndex("by_user", (q) => q.eq("userId", userId)).unique();
    const today = calls !== null && dayKey(calls.windowStart) === dayKey(now);
    if (today && calls.count >= suburbsPerUserPerDay) return "too many";
    if (calls === null) await ctx.db.insert("loreCalls", { userId, windowStart: now, count: 1 });
    else await ctx.db.patch("loreCalls", calls._id, { windowStart: today ? calls.windowStart : now, count: today ? calls.count + 1 : 1 });
    await queue(ctx, osmId, name, false);
    await startQueued(ctx);
    return "queued";
  },
});

async function queue(ctx: MutationCtx, osmId: number, name: string, manual: boolean) {
  const row = await placeRow(ctx, osmId);
  const now = Date.now();
  if (row === null) {
    await ctx.db.insert("lorePlaces", { osmId, name, status: "queued", version: 0, attempts: 0, queuedAt: now, cost: 0, runCost: 0, ...(manual ? { manual } : {}) });
  } else {
    await ctx.db.patch("lorePlaces", row._id, { status: "queued", queuedAt: now, retryAt: undefined, held: undefined, ...(manual ? { manual } : {}) });
  }
}

// The queue. A run starts when a slot's free and it can't take today's or this
// month's spending over its cap, even if every run going spends its whole limit.

/** Starts whatever can start now. Returns how many did. */
export async function startQueued(ctx: MutationCtx): Promise<number> {
  const running = await ctx.db.query("lorePlaces").withIndex("by_status", (q) => q.eq("status", "researching")).collect();
  const queued = await ctx.db.query("lorePlaces").withIndex("by_status", (q) => q.eq("status", "queued")).collect();
  if (queued.length === 0) return 0;
  const now = Date.now();
  const today = dayKey(now);
  const daily = await spentBetween(ctx, today, today);
  const monthly = await spentBetween(ctx, `${today.slice(0, 7)}-01`, `${today.slice(0, 7)}-31`);
  // What the runs going now could still spend before their own limit stops them.
  let reserved = running.reduce((sum, row) => sum + Math.max(0, caps.perRun - row.runCost), 0);
  let slots = maxRunning - running.length;
  let started = 0;
  for (const row of queued) {
    // Rows a walk queued wait while the switch is off; ones Mike asked for don't.
    if (!row.manual && !autoOn()) continue;
    const held = daily + reserved + caps.perRun > caps.daily ? "daily cap"
      : monthly + reserved + caps.perRun > caps.monthly ? "monthly cap" : undefined;
    if (held !== undefined || slots <= 0) {
      if (row.held !== held) await ctx.db.patch("lorePlaces", row._id, { held });
      continue;
    }
    const run = row.attempts + 1;
    await ctx.db.patch("lorePlaces", row._id, {
      status: "researching", held: undefined, attempts: run, startedAt: now, finishedAt: undefined, runCost: 0, error: undefined,
    });
    const workflowId = await workflow.start(ctx, internal.lorePipeline.run, { osmId: row.osmId, run }, {
      onComplete: internal.lore.runFinished, context: { osmId: row.osmId, run },
    });
    await ctx.db.patch("lorePlaces", row._id, { workflowId });
    reserved += caps.perRun;
    slots--;
    started++;
  }
  return started;
}

/** When a run ends. A successful one has already published itself (loreRun.publish). */
export const runFinished = internalMutation({
  args: { workflowId: vWorkflowId, result: vResultValidator, context: v.object({ osmId: v.number(), run: v.number() }) },
  returns: v.null(),
  handler: async (ctx, { result, context: { osmId, run } }) => {
    const row = await placeRow(ctx, osmId);
    if (row !== null && result.kind !== "success" && row.status === "researching" && row.attempts === run) {
      const error = result.kind === "failed" ? result.error : "Cancelled";
      const now = Date.now();
      // A run stopped at its spending limit would only spend it again, so Mike decides.
      const retry = !error.includes(overBudget) && row.attempts < maxAttempts;
      await ctx.db.patch("lorePlaces", row._id, {
        status: "failed", error: error.slice(0, 500), finishedAt: now, retryAt: retry ? now + failedRetry : undefined,
      });
      const unfinished = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
      for (const entry of unfinished.filter((e) => e.review === "checking")) {
        await ctx.db.patch("loreEntries", entry._id, { review: "dropped", droppedBy: "run stopped", checkNotes: [...entry.checkNotes, "The run stopped before it finished."] });
      }
    }
    await startQueued(ctx);
    return null;
  },
});

/** Hourly (crons.ts): quiet and failed places due another look go back on the queue,
 * and anything a cap held starts once the day or month rolls over. */
export const tick = internalMutation({
  args: {}, returns: v.null(),
  handler: async (ctx) => {
    if (autoOn()) {
      const due = await ctx.db.query("lorePlaces").withIndex("by_retry", (q) => q.gte("retryAt", 0).lte("retryAt", Date.now())).collect();
      for (const row of due) await queue(ctx, row.osmId, row.name, false);
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
    await queue(ctx, osmId, row?.name ?? "", true);
    const started = await startQueued(ctx);
    const after = await placeRow(ctx, osmId);
    return started > 0 && after?.status === "researching" ? "started" : `queued${after?.held ? ` (held by the ${after.held})` : ""}`;
  },
});

/**
 * Runs a finished run again from one of its steps, keeping what the steps before it
 * found and paid for: after a step broke on a bug, or a later step has changed.
 * Steps are named like "lorePipeline:write" (see lorePipeline.run).
 * `npx convex run lore:resume '{"osmId": 11688696, "from": "lorePipeline:write"}'`
 */
export const resume = internalMutation({
  args: { osmId: v.number(), from: v.optional(v.string()) },
  returns: v.null(),
  handler: async (ctx, { osmId, from }) => {
    const row = await placeRow(ctx, osmId);
    if (row?.workflowId === undefined || row.status === "researching" || row.status === "queued") {
      throw new ConvexError("Only a finished run can be resumed");
    }
    await ctx.db.patch("lorePlaces", row._id, { status: "researching", error: undefined, retryAt: undefined, finishedAt: undefined });
    const unfinished = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", row.attempts)).collect();
    for (const entry of unfinished.filter((e) => e.droppedBy === "run stopped")) {
      await ctx.db.patch("loreEntries", entry._id, { review: "checking", droppedBy: undefined, checkNotes: entry.checkNotes.slice(0, -1) });
    }
    await restart(ctx, components.workflow, row.workflowId as never, { ...(from ? { from } : {}), startAsync: true });
    return null;
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
  entryId: v.string(), osmId: v.number(), title: v.string(), body: v.string(), category: v.string(),
  place: v.optional(vPlace), sources: v.array(v.string()), sensitive: v.array(v.string()),
  review: vLoreReview, droppedBy: v.optional(v.string()), checkNotes: v.array(v.string()),
  claims: v.array(v.object({ text: v.string(), url: v.string(), quote: v.string(), found: v.optional(v.boolean()) })),
  stickerUrl: v.union(v.string(), v.null()),
});

async function forReview(ctx: QueryCtx, entry: Doc<"loreEntries">) {
  return {
    entryId: entry.entryId, osmId: entry.osmId, title: entry.title, body: entry.body, category: entry.category,
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
    await ctx.db.patch("loreEntries", entry._id, { review });
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
      month: await spentBetween(ctx, `${today.slice(0, 7)}-01`, `${today.slice(0, 7)}-31`),
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


// The database side of a research run: spend, notes, drafts and what the checks
// decided, called by the steps in lorePipeline.ts. Nothing here talks to the web.
import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { caps, entries as wanted, firstNationsSources, quietRetry } from "./loreConfig";
import { onDomains, sensitiveWords } from "./loreChecks";

export async function placeRow(ctx: QueryCtx, osmId: number) {
  return await ctx.db.query("lorePlaces").withIndex("by_osm", (q) => q.eq("osmId", osmId)).unique();
}

/** The live secrets changed, so the phones should fetch them again. */
export async function bumpVersion(ctx: MutationCtx, osmId: number) {
  const row = await placeRow(ctx, osmId);
  if (row) await ctx.db.patch("lorePlaces", row._id, { version: row.version + 1 });
}

/** A UTC day, "2026-10-24". The caps count by these. */
export const dayKey = (ms: number) => new Date(ms).toISOString().slice(0, 10);

/** Dollars spent from the start of `from` to the end of `to` (both days). */
export async function spentBetween(ctx: QueryCtx, from: string, to: string): Promise<number> {
  const rows = await ctx.db.query("loreSpend").withIndex("by_day", (q) => q.gte("day", from).lte("day", to)).collect();
  return rows.reduce((sum, row) => sum + row.cost, 0);
}

/** Thrown when a run reaches caps.perRun. lore.runFinished doesn't retry these. */
export const overBudget = "Over budget:";
export const budgetMessage = (spent: number) => `${overBudget} this run has spent $${spent.toFixed(2)}, and stops at $${caps.perRun}.`;

/** Adds one OpenRouter call's `usage.cost`. Returns what this run has spent so far. */
export const recordSpend = internalMutation({
  args: { osmId: v.number(), step: v.string(), cost: v.number() },
  returns: v.number(),
  handler: async (ctx, { osmId, step, cost }) => {
    const day = dayKey(Date.now());
    const row = await ctx.db.query("loreSpend").withIndex("by_day", (q) => q.eq("day", day).eq("osmId", osmId).eq("step", step)).unique();
    if (row) await ctx.db.patch("loreSpend", row._id, { cost: row.cost + cost, calls: row.calls + 1 });
    else await ctx.db.insert("loreSpend", { day, osmId, step, cost, calls: 1 });
    const place = await placeRow(ctx, osmId);
    if (place === null) return cost;
    await ctx.db.patch("lorePlaces", place._id, { cost: place.cost + cost, runCost: place.runCost + cost });
    return place.runCost + cost;
  },
});

/** Between steps: stops the run once it has spent its limit. */
export const checkBudget = internalQuery({
  args: { osmId: v.number() }, returns: v.number(),
  handler: async (ctx, { osmId }) => {
    const spent = (await placeRow(ctx, osmId))?.runCost ?? 0;
    if (spent >= caps.perRun) throw new Error(budgetMessage(spent));
    return spent;
  },
});

const vPlaceInfo = { name: v.string(), displayName: v.string(), region: v.string(), country: v.string() };

/** What a step needs to know about the place it's researching. */
export const brief = internalQuery({
  args: { osmId: v.number() },
  returns: v.object({ ...vPlaceInfo, runCost: v.number() }),
  handler: async (ctx, { osmId }) => {
    const row = await placeRow(ctx, osmId);
    if (row === null) throw new Error("No such lore place");
    return { name: row.name, displayName: row.displayName ?? row.name, region: row.region ?? "", country: row.country ?? "", runCost: row.runCost };
  },
});

export const setPlaceInfo = internalMutation({
  args: { osmId: v.number(), ...vPlaceInfo }, returns: v.null(),
  handler: async (ctx, { osmId, ...info }) => {
    const row = await placeRow(ctx, osmId);
    if (row) await ctx.db.patch("lorePlaces", row._id, info);
    return null;
  },
});

const vSpot = v.object({ name: v.string(), lat: v.optional(v.number()), lon: v.optional(v.number()) });

/**
 * One research note. Returns how many this angle has saved this run, and what the
 * other angles have saved, so the three researchers don't all find the same story.
 */
export const saveNote = internalMutation({
  args: { osmId: v.number(), run: v.number(), angle: v.string(), fact: v.string(), url: v.string(), quote: v.string(), spot: v.optional(vSpot) },
  returns: v.object({ saved: v.number(), others: v.array(v.string()) }),
  handler: async (ctx, note) => {
    await ctx.db.insert("loreNotes", note);
    const all = await ctx.db.query("loreNotes").withIndex("by_osm_run", (q) => q.eq("osmId", note.osmId).eq("run", note.run)).collect();
    return {
      saved: all.filter((n) => n.angle === note.angle).length,
      others: all.filter((n) => n.angle !== note.angle).map((n) => n.fact),
    };
  },
});

export const notes = internalQuery({
  args: { osmId: v.number(), run: v.number() },
  returns: v.array(v.object({ angle: v.string(), fact: v.string(), url: v.string(), quote: v.string(), spot: v.optional(vSpot) })),
  handler: async (ctx, { osmId, run }) => {
    const rows = await ctx.db.query("loreNotes").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
    return rows.map(({ angle, fact, url, quote, spot }) => ({ angle, fact, url, quote, ...(spot ? { spot } : {}) }));
  },
});

/** Titles from earlier runs, so a second look doesn't write the same story again. */
export const earlierTitles = internalQuery({
  args: { osmId: v.number(), run: v.number() }, returns: v.array(v.string()),
  handler: async (ctx, { osmId, run }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).lt("run", run)).collect();
    return rows.filter((e) => e.review !== "dropped").map((e) => e.title);
  },
});

const vClaim = v.object({ text: v.string(), url: v.string(), quote: v.string(), found: v.optional(v.boolean()), context: v.optional(v.string()) });
const vDraft = v.object({
  slug: v.string(), title: v.string(), body: v.string(), category: v.string(),
  place: v.optional(v.object({ name: v.string(), lat: v.number(), lon: v.number() })),
  sticker: v.string(), claims: v.array(v.object({ text: v.string(), url: v.string(), quote: v.string() })), sensitive: v.array(v.string()),
});

/** The writer's drafts, all "checking" until the checks are done. Returns their ids. */
export const saveDrafts = internalMutation({
  args: { osmId: v.number(), run: v.number(), suburb: v.string(), drafts: v.array(vDraft) },
  returns: v.array(v.string()),
  handler: async (ctx, { osmId, run, suburb, drafts }) => {
    const ids: string[] = [];
    for (const draft of drafts) {
      const base = `osm${osmId}-${draft.slug.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60) || "secret"}`;
      let entryId = base;
      for (let n = 2; await ctx.db.query("loreEntries").withIndex("by_entry", (q) => q.eq("entryId", entryId)).first(); n++) entryId = `${base}-${n}`;
      const { slug: _slug, ...fields } = draft;
      await ctx.db.insert("loreEntries", {
        ...fields, osmId, run, entryId, suburb, sources: [...new Set(draft.claims.map((c) => c.url))], review: "checking", checkNotes: [],
      });
      ids.push(entryId);
    }
    return ids;
  },
});

const vStoredEntry = v.object({
  entryId: v.string(), title: v.string(), body: v.string(), category: v.string(),
  place: v.optional(v.object({ name: v.string(), lat: v.number(), lon: v.number() })),
  sticker: v.string(), claims: v.array(vClaim), sensitive: v.array(v.string()), checkNotes: v.array(v.string()),
  stickerFile: v.optional(v.id("_storage")),
});

/** This run's entries still in the running. */
export const checking = internalQuery({
  args: { osmId: v.number(), run: v.number() }, returns: v.array(vStoredEntry),
  handler: async (ctx, { osmId, run }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
    return rows.filter((e) => e.review === "checking").map((e) => ({
      entryId: e.entryId, title: e.title, body: e.body, category: e.category, ...(e.place ? { place: e.place } : {}),
      sticker: e.sticker, claims: e.claims, sensitive: e.sensitive, checkNotes: e.checkNotes, ...(e.stickerFile ? { stickerFile: e.stickerFile } : {}),
    }));
  },
});

async function entryRow(ctx: QueryCtx, entryId: string) {
  const row = await ctx.db.query("loreEntries").withIndex("by_entry", (q) => q.eq("entryId", entryId)).unique();
  if (row === null) throw new Error(`No entry ${entryId}`);
  return row;
}

/**
 * What a check found. `notes` are added to checkNotes; `drop` takes the entry out
 * with the check's name. A place of null removes the pin, so it's scattered instead.
 */
export const updateEntry = internalMutation({
  args: {
    entryId: v.string(),
    title: v.optional(v.string()),
    body: v.optional(v.string()),
    claims: v.optional(v.array(vClaim)),
    sensitive: v.optional(v.array(v.string())),
    place: v.optional(v.union(v.null(), v.object({ name: v.string(), lat: v.number(), lon: v.number() }))),
    stickerFile: v.optional(v.id("_storage")),
    notes: v.optional(v.array(v.string())),
    drop: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { entryId, title, body, claims, sensitive, place, stickerFile, notes, drop }) => {
    const row = await entryRow(ctx, entryId);
    const patch: Partial<Doc<"loreEntries">> = { checkNotes: [...row.checkNotes, ...(notes ?? [])] };
    if (title !== undefined) patch.title = title;
    if (body !== undefined) patch.body = body;
    if (claims) {
      patch.claims = claims;
      patch.sources = [...new Set(claims.filter((c) => c.found !== false).map((c) => c.url))];
    }
    if (sensitive) patch.sensitive = [...new Set([...row.sensitive, ...sensitive])].sort();
    if (place !== undefined) patch.place = place ?? undefined;
    if (stickerFile) {
      if (row.stickerFile) await ctx.storage.delete(row.stickerFile);
      patch.stickerFile = stickerFile;
      // A sticker redrawn for a secret that's already live (lore:resume from a sticker
      // step) is a change the phones should fetch.
      if (row.review === "auto" || row.review === "approved") await bumpVersion(ctx, row.osmId);
    }
    if (drop && row.review === "checking") {
      patch.review = "dropped";
      patch.droppedBy = drop;
    }
    await ctx.db.patch("loreEntries", row._id, patch);
    return null;
  },
});

/**
 * The rules that don't need a model, after the fact-check: what makes a secret wait
 * for Mike, and the First Nations rules. Outside WA those stories are left out
 * entirely for now; in WA every source has to be one of firstNationsSources.
 */
export const applyRules = internalMutation({
  args: { osmId: v.number(), run: v.number(), wa: v.boolean() }, returns: v.null(),
  handler: async (ctx, { osmId, run, wa }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
    for (const row of rows.filter((e) => e.review === "checking")) {
      const sensitive = [...new Set([...row.sensitive, ...sensitiveWords(`${row.title}\n${row.body}`), ...(row.category === "first-nations" ? ["first-nations"] : [])])].sort();
      const patch: Partial<Doc<"loreEntries">> = { sensitive };
      if (sensitive.includes("first-nations")) {
        const outside = row.sources.filter((url) => !onDomains(url, firstNationsSources));
        const reason = !wa ? "First Nations stories are only written for Western Australia for now."
          : outside.length > 0 ? `First Nations stories only use the approved sources, and this one cites ${outside.join(", ")}.` : null;
        if (reason) Object.assign(patch, { review: "dropped", droppedBy: "rules", checkNotes: [...row.checkNotes, reason] });
      }
      // The style guide has no em dashes. A comma reads the same in these.
      if (patch.review === undefined && row.body.includes("—")) patch.body = row.body.replace(/\s*—\s*/g, ", ");
      await ctx.db.patch("loreEntries", row._id, patch);
    }
    return null;
  },
});

/**
 * The last step. Sensitive secrets wait for Mike; the rest go live. A place with
 * fewer than `entries.enough` secrets in all is quiet, and gets one more look later.
 */
export const publish = internalMutation({
  args: { osmId: v.number(), run: v.number() },
  returns: v.object({ live: v.number(), pending: v.number(), dropped: v.number(), status: v.string() }),
  handler: async (ctx, { osmId, run }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
    let live = 0, pending = 0;
    for (const row of rows.filter((e) => e.review === "checking")) {
      const review = row.sensitive.length > 0 ? "pending" : "auto";
      await ctx.db.patch("loreEntries", row._id, { review });
      if (review === "auto") live++;
      else pending++;
    }
    const all = await ctx.db.query("loreEntries").withIndex("by_osm_review", (q) => q.eq("osmId", osmId)).collect();
    const kept = all.filter((e) => ["auto", "approved", "pending"].includes(e.review)).length;
    const place = await placeRow(ctx, osmId);
    const quiet = kept < wanted.enough;
    if (place) {
      const now = Date.now();
      await ctx.db.patch("lorePlaces", place._id, {
        status: quiet ? "quiet" : "ready", finishedAt: now, version: place.version + (live > 0 ? 1 : 0),
        // Only the first quiet run gets a second look.
        retryAt: quiet && place.attempts < 2 ? now + quietRetry : undefined,
      });
    }
    return { live, pending, dropped: rows.filter((e) => e.review === "dropped").length, status: quiet ? "quiet" : "ready" };
  },
});

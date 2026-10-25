// The database side of a research run: spend, notes, drafts and what the checks
// decided, called by the steps in lorePipeline.ts. Nothing here talks to the web.
import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { caps, entries as wanted, firstNationsSources, holds as holdRules, quietRetry } from "./loreConfig";
import { overBudget } from "./loreBudget";
import { leadOnlyProblem, onDomains, sensitiveWords } from "./loreChecks";

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

/** The first and last day keys of the month `day` is in, for spentBetween. */
export const monthOf = (day: string): [string, string] => [`${day.slice(0, 7)}-01`, `${day.slice(0, 7)}-31`];

/** Dollars spent from the start of `from` to the end of `to` (both days), holds on calls
 * still going included at the most they could cost. */
export async function spentBetween(ctx: QueryCtx, from: string, to: string): Promise<number> {
  const rows = await ctx.db.query("loreSpend").withIndex("by_day", (q) => q.gte("day", from).lte("day", to)).collect();
  return rows.reduce((sum, row) => sum + row.cost, 0);
}

export const budgetMessage = (spent: number, next = 0) => next > 0
  ? `${overBudget} this run has spent $${spent.toFixed(2)} and stops at $${caps.perRun}, so it can't make a call that could cost $${next.toFixed(2)}.`
  : `${overBudget} this run has spent $${spent.toFixed(2)}, and stops at $${caps.perRun}.`;

// Floating point sums of holds leave crumbs like 1e-17; a hold that's gone is 0.
const tidy = (n: number) => Math.abs(n) < 1e-9 ? 0 : n;

async function addSpend(ctx: MutationCtx, day: string, osmId: number, step: string, change: { cost: number; held: number; unpriced?: number; calls?: number }) {
  const row = await ctx.db.query("loreSpend").withIndex("by_day", (q) => q.eq("day", day).eq("osmId", osmId).eq("step", step)).unique();
  if (row) {
    await ctx.db.patch("loreSpend", row._id, {
      cost: tidy(row.cost + change.cost), calls: row.calls + (change.calls ?? 0), held: tidy((row.held ?? 0) + change.held),
      ...(change.unpriced ? { unpriced: (row.unpriced ?? 0) + change.unpriced } : {}),
    });
  } else {
    await ctx.db.insert("loreSpend", {
      day, osmId, step, cost: change.cost, calls: change.calls ?? 0, held: change.held, ...(change.unpriced ? { unpriced: change.unpriced } : {}),
    });
  }
}

/**
 * Books a hold for one paid call before it's sent: `amount` is the most it could cost
 * (loreBudget.callBound). Refuses, saying why, if that could take this budget segment,
 * today or this month over its cap. The hold counts as spent straight away, so calls
 * made at the same time can't all pass the same check.
 */
export const reserve = internalMutation({
  args: { osmId: v.number(), step: v.string(), amount: v.number() },
  returns: v.union(v.object({ holdId: v.id("loreHolds") }), v.object({ refused: v.string() })),
  handler: async (ctx, { osmId, step, amount }) => {
    if (!Number.isFinite(amount) || amount < 0) throw new Error("A hold needs the most a call can cost");
    const place = await placeRow(ctx, osmId);
    const runCost = place?.runCost ?? 0;
    if (runCost + amount > caps.perRun) return { refused: budgetMessage(runCost, amount) };
    const now = Date.now();
    const day = dayKey(now);
    const today = await spentBetween(ctx, day, day);
    if (today + amount > caps.daily) {
      return { refused: `${overBudget} today's spending is at $${today.toFixed(2)} of the $${caps.daily} daily cap, so it can't make a call that could cost $${amount.toFixed(2)}.` };
    }
    const month = await spentBetween(ctx, ...monthOf(day));
    if (month + amount > caps.monthly) {
      return { refused: `${overBudget} this month's spending is at $${month.toFixed(2)} of the $${caps.monthly} monthly cap, so it can't make a call that could cost $${amount.toFixed(2)}.` };
    }
    await addSpend(ctx, day, osmId, step, { cost: amount, held: amount, calls: 1 });
    if (place) await ctx.db.patch("lorePlaces", place._id, { cost: place.cost + amount, runCost: runCost + amount });
    return { holdId: await ctx.db.insert("loreHolds", { osmId, day, step, amount, segment: place?.segment ?? 0, at: now }) };
  },
});

/** Turns a hold into what the call really cost, or keeps all of it if `cost` is unknown. */
async function release(ctx: MutationCtx, hold: Doc<"loreHolds">, cost: number | undefined) {
  const known = cost !== undefined && Number.isFinite(cost) && cost >= 0;
  const change = known ? cost - hold.amount : 0;
  if (known && change > 0) console.warn(`A ${hold.step} call for ${hold.osmId} cost $${cost} against a hold of $${hold.amount}`);
  await addSpend(ctx, hold.day, hold.osmId, hold.step, { cost: change, held: -hold.amount, ...(known ? {} : { unpriced: hold.amount }) });
  const place = await placeRow(ctx, hold.osmId);
  if (place && change !== 0) {
    // A late answer from before a resume belongs to the old segment, not the new one's budget.
    const sameSegment = (place.segment ?? 0) === hold.segment;
    await ctx.db.patch("lorePlaces", place._id, { cost: tidy(place.cost + change), ...(sameSegment ? { runCost: tidy(place.runCost + change) } : {}) });
  }
  await ctx.db.delete("loreHolds", hold._id);
}

/** After a call: settles its hold to `cost`, or keeps the hold as spent when there's
 * no cost (missing usage never counts as free). Returns what the segment has spent. */
export const settle = internalMutation({
  args: { holdId: v.id("loreHolds"), cost: v.optional(v.number()) },
  returns: v.number(),
  handler: async (ctx, { holdId, cost }) => {
    const hold = await ctx.db.get("loreHolds", holdId);
    // Already kept as spent by lore.tick, after the call took longer than an hour.
    if (hold === null) return 0;
    await release(ctx, hold, cost);
    return (await placeRow(ctx, hold.osmId))?.runCost ?? 0;
  },
});

/** Holds older than holds.staleAfter belong to calls that crashed or were cut off. They're kept as spent. */
export async function releaseStale(ctx: MutationCtx): Promise<number> {
  const stale = await ctx.db.query("loreHolds").withIndex("by_at", (q) => q.lt("at", Date.now() - holdRules.staleAfter)).take(200);
  for (const hold of stale) await release(ctx, hold, undefined);
  return stale.length;
}

/** Between steps: stops the run once it has spent its limit. */
export const checkBudget = internalQuery({
  args: { osmId: v.number() }, returns: v.number(),
  handler: async (ctx, { osmId }) => {
    const spent = (await placeRow(ctx, osmId))?.runCost ?? 0;
    if (spent >= caps.perRun) throw new Error(budgetMessage(spent));
    return spent;
  },
});

/** A research agent's thread, so it can be deleted when the run's done (lore.cleanUpRun). */
export const saveThread = internalMutation({
  args: { osmId: v.number(), run: v.number(), threadId: v.string() }, returns: v.null(),
  handler: async (ctx, thread) => {
    await ctx.db.insert("loreThreads", thread);
    return null;
  },
});

/** Deletes a secret's sticker file, for one that's dropped, hidden or replaced. */
export async function deleteSticker(ctx: MutationCtx, entry: Doc<"loreEntries">) {
  if (entry.stickerFile && await ctx.db.system.get("_storage", entry.stickerFile)) await ctx.storage.delete(entry.stickerFile);
}

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

const published = (e: Doc<"loreEntries">) => e.review !== "checking" && e.review !== "dropped";
/** Lower case letters and digits, so two titles for the same story compare equal. */
const titleKey = (title: string) => title.toLowerCase().replace(/[^a-z0-9]+/g, "");

/** Titles already out for this place, from any run (this one too, when it's resumed), so
 * a second look or a rewrite doesn't write the same story again. Hidden ones count. */
export const earlierTitles = internalQuery({
  args: { osmId: v.number(), run: v.number() }, returns: v.array(v.string()),
  handler: async (ctx, { osmId }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId)).collect();
    return rows.filter(published).map((e) => e.title);
  },
});

const vClaim = v.object({ text: v.string(), url: v.string(), quote: v.string(), found: v.optional(v.boolean()), context: v.optional(v.string()) });
const vDraft = v.object({
  slug: v.string(), title: v.string(), body: v.string(), category: v.string(),
  place: v.optional(v.object({ name: v.string(), lat: v.number(), lon: v.number() })),
  sticker: v.string(), claims: v.array(v.object({ text: v.string(), url: v.string(), quote: v.string() })), sensitive: v.array(v.string()),
});

/**
 * The writer's drafts, all "checking" until the checks are done. Returns their ids.
 * A retried or resumed write replaces this run's own unfinished drafts (checking or
 * dropped) instead of adding to them, so the same slug gets the same id. A draft for a
 * story that's already out (this run's, or any run's with the same title) is skipped.
 */
export const saveDrafts = internalMutation({
  args: { osmId: v.number(), run: v.number(), suburb: v.string(), drafts: v.array(vDraft) },
  returns: v.array(v.string()),
  handler: async (ctx, { osmId, run, suburb, drafts }) => {
    const all = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId)).collect();
    for (const row of all.filter((e) => e.run === run && !published(e))) {
      await deleteSticker(ctx, row);
      await ctx.db.delete("loreEntries", row._id);
    }
    const out = all.filter(published);
    const titles = new Set(out.map((e) => titleKey(e.title)));
    const ids: string[] = [];
    for (const draft of drafts) {
      const base = `osm${osmId}-${draft.slug.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60) || "secret"}`;
      const sameStory = (e: Doc<"loreEntries">) => e.run === run && (e.entryId === base || new RegExp(`^${base}-\\d+$`).test(e.entryId));
      if (titles.has(titleKey(draft.title)) || out.some(sameStory)) continue;
      titles.add(titleKey(draft.title));
      // Another run (or a different story in this one) already has the slug.
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
  stickerFile: v.optional(v.id("_storage")), factChecked: v.optional(v.boolean()),
});

/** This run's entries still in the running. */
export const checking = internalQuery({
  args: { osmId: v.number(), run: v.number() }, returns: v.array(vStoredEntry),
  handler: async (ctx, { osmId, run }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
    return rows.filter((e) => e.review === "checking").map((e) => ({
      entryId: e.entryId, title: e.title, body: e.body, category: e.category, ...(e.place ? { place: e.place } : {}),
      sticker: e.sticker, claims: e.claims, sensitive: e.sensitive, checkNotes: e.checkNotes, ...(e.stickerFile ? { stickerFile: e.stickerFile } : {}),
      ...(e.factChecked ? { factChecked: true } : {}),
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
    factChecked: v.optional(v.boolean()),
    notes: v.optional(v.array(v.string())),
    drop: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { entryId, title, body, claims, sensitive, place, stickerFile, factChecked, notes, drop }) => {
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
    if (factChecked) patch.factChecked = true;
    if (stickerFile) {
      // Dropped or hidden while it was being drawn: nobody will ever see this one.
      if (row.review === "dropped" || row.review === "hidden") {
        await ctx.storage.delete(stickerFile);
      } else {
        await deleteSticker(ctx, row);
        patch.stickerFile = stickerFile;
        // A sticker drawn later for a secret that's already live (lore:resume from
        // "stickers") is a change the phones should fetch.
        if (row.review === "auto" || row.review === "approved") await bumpVersion(ctx, row.osmId);
      }
    }
    if (drop && row.review === "checking") {
      patch.review = "dropped";
      patch.droppedBy = drop;
      await deleteSticker(ctx, row);
      patch.stickerFile = undefined;
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
      let reason: string | null = null;
      if (sensitive.includes("first-nations")) {
        const outside = row.sources.filter((url) => !onDomains(url, firstNationsSources));
        reason = !wa ? "First Nations stories are only written for Western Australia for now."
          : outside.length > 0 ? `First Nations stories only use the approved sources, and this one cites ${outside.join(", ")}.` : null;
      }
      // The quote check already treats these as unsourced; this catches anything that got past it.
      reason ??= leadOnlyProblem(row.claims.filter((c) => c.found !== false).map((c) => c.url));
      if (reason) {
        Object.assign(patch, { review: "dropped", droppedBy: "rules", checkNotes: [...row.checkNotes, reason], stickerFile: undefined });
        await deleteSticker(ctx, row);
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
    let live = 0, pending = 0, unchecked = 0;
    for (const row of rows.filter((e) => e.review === "checking")) {
      // Never published without passing the fact-check: one the run couldn't afford to
      // check, say, or one lore:resume brought back without checking again.
      if (!row.factChecked) {
        await deleteSticker(ctx, row);
        await ctx.db.patch("loreEntries", row._id, {
          review: "dropped", droppedBy: "not checked", stickerFile: undefined,
          checkNotes: [...row.checkNotes, "It hadn't been fact-checked when the run published, so it's left out."],
        });
        unchecked++;
        continue;
      }
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
    return { live, pending, dropped: rows.filter((e) => e.review === "dropped").length + unchecked, status: quiet ? "quiet" : "ready" };
  },
});

/**
 * This run's secrets still in the running or out without a sticker, for the sticker
 * steps. The workflow names this step "stickers", so `lore:resume` with
 * `"from": "stickers"` draws the missing ones later.
 */
export const needStickers = internalQuery({
  args: { osmId: v.number(), run: v.number() },
  returns: v.array(v.object({ entryId: v.string(), sticker: v.string() })),
  handler: async (ctx, { osmId, run }) => {
    const rows = await ctx.db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
    return rows.filter((e) => ["checking", "auto", "pending", "approved"].includes(e.review) && !e.stickerFile)
      .map((e) => ({ entryId: e.entryId, sticker: e.sticker }));
  },
});

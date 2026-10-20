import { ConvexError, v } from "convex/values";
import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { currentUserId } from "./users";
import { mergeLedgers, parseLedger } from "./progression";

async function requireUser(ctx: QueryCtx | MutationCtx) {
  const userId = await currentUserId(ctx);
  if (userId === null) throw new ConvexError("Not signed in");
  return userId;
}

/** Where to upload a walk or city file before saving it. */
export const generateUploadUrl = mutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => {
    await requireUser(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/** Replaces a finished walk so its raw GPS survives while derived coverage is rebuilt. */
export const saveWalk = mutation({
  args: {
    gridVersion: v.literal(2),
    clientId: v.string(),
    startedAt: v.number(),
    endedAt: v.number(),
    distance: v.number(),
    newTiles: v.number(),
    file: v.id("_storage"),
  },
  returns: v.null(),
  handler: async (ctx, { gridVersion: _gridVersion, ...walk }) => {
    const userId = await requireUser(ctx);
    const existing = await ctx.db
      .query("walks")
      .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", walk.clientId))
      .unique();
    if (existing !== null) {
      await ctx.db.patch("walks", existing._id, walk);
      if (existing.file !== walk.file) await ctx.storage.delete(existing.file);
      return null;
    }
    await ctx.db.insert("walks", { userId, ...walk });
    return null;
  },
});

/** Saves a city, keeping whichever copy is newest. */
export const savePlace = mutation({
  args: {
    gridVersion: v.literal(2),
    clientId: v.string(),
    name: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
    file: v.id("_storage"),
  },
  returns: v.null(),
  handler: async (ctx, { gridVersion: _gridVersion, ...place }) => {
    const userId = await requireUser(ctx);
    const existing = await ctx.db
      .query("places")
      .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", place.clientId))
      .unique();
    if (existing === null) {
      await ctx.db.insert("places", { userId, ...place });
    } else if (place.updatedAt > existing.updatedAt) {
      await ctx.db.patch("places", existing._id, { name: place.name, updatedAt: place.updatedAt, file: place.file });
      await ctx.storage.delete(existing.file);
    } else {
      await ctx.storage.delete(place.file);
    }
    return null;
  },
});

export const deletePlace = mutation({
  args: { gridVersion: v.literal(2), clientId: v.string() },
  returns: v.null(),
  handler: async (ctx, { clientId }) => {
    const userId = await requireUser(ctx);
    const existing = await ctx.db
      .query("places")
      .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", clientId))
      .unique();
    if (existing !== null) {
      await ctx.db.delete("places", existing._id);
      await ctx.storage.delete(existing.file);
    }
    return null;
  },
});

/** Records found secrets, keeping the earliest time each was found. */
export const saveSecrets = mutation({
  args: { gridVersion: v.literal(2), secrets: v.array(v.object({ secretId: v.string(), foundAt: v.number() })) },
  returns: v.null(),
  handler: async (ctx, { secrets }) => {
    const userId = await requireUser(ctx);
    for (const { secretId, foundAt } of secrets) {
      const existing = await ctx.db
        .query("secrets")
        .withIndex("by_user_secret", (q) => q.eq("userId", userId).eq("secretId", secretId))
        .unique();
      if (existing === null) {
        await ctx.db.insert("secrets", { userId, secretId, foundAt });
      } else if (foundAt < existing.foundAt) {
        await ctx.db.patch("secrets", existing._id, { foundAt });
      }
    }
    return null;
  },
});

/** The stored copy wins duplicate ids and claims; equipment uses its own clock. */
export const saveProgress = mutation({
  args: { gridVersion: v.literal(2), ledger: v.string() },
  returns: v.null(),
  handler: async (ctx, { ledger }) => {
    const userId = await requireUser(ctx);
    const incoming = parseLedger(ledger);
    const existing = await ctx.db.query("progress").withIndex("by_user", (q) => q.eq("userId", userId)).unique();
    const merged = existing === null ? mergeLedgers(incoming, incoming) : mergeLedgers(parseLedger(existing.ledger), incoming);
    const data = { ledger: JSON.stringify(merged), updatedAt: Date.now() };
    if (existing === null) await ctx.db.insert("progress", { userId, ...data });
    else await ctx.db.patch("progress", existing._id, data);
    return null;
  },
});

/**
 * Everything the server has for the signed-in user, without the walk and city
 * contents. The phone downloads only the files it's missing. With `walkUrls: false`
 * walks come without links, and the phone asks `walkUrls` for the ones it hasn't got.
 */
export const snapshot = query({
  args: { walkUrls: v.optional(v.boolean()) },
  returns: v.object({
    walks: v.array(v.object({ clientId: v.string(), url: v.union(v.string(), v.null()) })),
    places: v.array(
      v.object({ clientId: v.string(), updatedAt: v.number(), url: v.union(v.string(), v.null()) }),
    ),
    secrets: v.array(v.object({ secretId: v.string(), foundAt: v.number() })),
    progress: v.union(v.string(), v.null()),
  }),
  handler: async (ctx, { walkUrls }) => {
    const userId = await requireUser(ctx);
    const [walks, places, secrets, progress] = await Promise.all([
      ctx.db.query("walks").withIndex("by_user_client", (q) => q.eq("userId", userId)).collect(),
      ctx.db.query("places").withIndex("by_user_client", (q) => q.eq("userId", userId)).collect(),
      ctx.db.query("secrets").withIndex("by_user_secret", (q) => q.eq("userId", userId)).collect(),
      ctx.db.query("progress").withIndex("by_user", (q) => q.eq("userId", userId)).unique(),
    ]);
    return {
      walks: await Promise.all(walks.map(async (w) => ({
        clientId: w.clientId, url: walkUrls === false ? null : await ctx.storage.getUrl(w.file),
      }))),
      places: await Promise.all(
        places.map(async (p) => ({ clientId: p.clientId, updatedAt: p.updatedAt, url: await ctx.storage.getUrl(p.file) })),
      ),
      secrets: secrets.map((s) => ({ secretId: s.secretId, foundAt: s.foundAt })),
      progress: progress?.ledger ?? null,
    };
  },
});

/** Download links for these walks, for the ones the phone hasn't got. */
export const walkUrls = query({
  args: { clientIds: v.array(v.string()) },
  returns: v.array(v.object({ clientId: v.string(), url: v.union(v.string(), v.null()) })),
  handler: async (ctx, { clientIds }) => {
    const userId = await requireUser(ctx);
    if (clientIds.length > 100) throw new ConvexError("Too many walks");
    const found = [];
    for (const clientId of new Set(clientIds)) {
      const walk = await ctx.db.query("walks").withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", clientId)).unique();
      if (walk) found.push({ clientId, url: await ctx.storage.getUrl(walk.file) });
    }
    return found;
  },
});

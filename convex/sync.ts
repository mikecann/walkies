import { ConvexError, v } from "convex/values";
import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";

async function requireUser(ctx: QueryCtx | MutationCtx) {
  const userId = await getAuthUserId(ctx);
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

/** Saves a finished walk. Safe to retry: a walk the server already has is ignored. */
export const saveWalk = mutation({
  args: {
    clientId: v.string(),
    startedAt: v.number(),
    endedAt: v.number(),
    distance: v.number(),
    newTiles: v.number(),
    file: v.id("_storage"),
  },
  returns: v.null(),
  handler: async (ctx, walk) => {
    const userId = await requireUser(ctx);
    const existing = await ctx.db
      .query("walks")
      .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", walk.clientId))
      .unique();
    if (existing !== null) {
      await ctx.storage.delete(walk.file);
      return null;
    }
    await ctx.db.insert("walks", { userId, ...walk });
    return null;
  },
});

/** Saves a city, keeping whichever copy is newest. */
export const savePlace = mutation({
  args: {
    clientId: v.string(),
    name: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
    file: v.id("_storage"),
  },
  returns: v.null(),
  handler: async (ctx, place) => {
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
  args: { clientId: v.string() },
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
  args: { secrets: v.array(v.object({ secretId: v.string(), foundAt: v.number() })) },
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

/**
 * Everything the server has for the signed-in user, without the walk and city
 * contents. The phone downloads only the files it's missing.
 */
export const snapshot = query({
  args: {},
  returns: v.object({
    walks: v.array(v.object({ clientId: v.string(), url: v.union(v.string(), v.null()) })),
    places: v.array(
      v.object({ clientId: v.string(), updatedAt: v.number(), url: v.union(v.string(), v.null()) }),
    ),
    secrets: v.array(v.object({ secretId: v.string(), foundAt: v.number() })),
  }),
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const [walks, places, secrets] = await Promise.all([
      ctx.db.query("walks").withIndex("by_user_client", (q) => q.eq("userId", userId)).collect(),
      ctx.db.query("places").withIndex("by_user_client", (q) => q.eq("userId", userId)).collect(),
      ctx.db.query("secrets").withIndex("by_user_secret", (q) => q.eq("userId", userId)).collect(),
    ]);
    return {
      walks: await Promise.all(walks.map(async (w) => ({ clientId: w.clientId, url: await ctx.storage.getUrl(w.file) }))),
      places: await Promise.all(
        places.map(async (p) => ({ clientId: p.clientId, updatedAt: p.updatedAt, url: await ctx.storage.getUrl(p.file) })),
      ),
      secrets: secrets.map((s) => ({ secretId: s.secretId, foundAt: s.foundAt })),
    };
  },
});

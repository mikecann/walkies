import { v } from "convex/values";
import { getAuthUserId } from "@convex-dev/auth/server";
import { internalMutation, query } from "./_generated/server";
import { components } from "./_generated/api";

export const createUser = internalMutation({
  args: {
    provider: v.object({
      name: v.literal("passkey"),
      accountId: v.string(),
      profile: v.object({}),
    }),
  },
  returns: v.id("users"),
  handler: async (ctx) => {
    return await ctx.db.insert("users", {});
  },
});

/** The signed-in user's username, or null when signed out. */
export const me = query({
  args: {},
  returns: v.union(v.null(), v.object({ username: v.union(v.string(), v.null()) })),
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (userId === null) return null;
    const username = await ctx.runQuery(components.authUsername.public.getUsername, { userId });
    return { username };
  },
});

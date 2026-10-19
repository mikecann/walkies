import { v } from "convex/values";
import { getAuthUserId } from "@convex-dev/auth/server";
import { vAppleProfile } from "@convex-dev/auth/methods/apple/server";
import { vGoogleProfile } from "@convex-dev/auth/methods/google/server";
import { internalMutation, query, type MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";

const vApple = v.object({ name: v.literal("apple"), accountId: v.string(), profile: vAppleProfile });
const vGoogle = v.object({ name: v.literal("google"), accountId: v.string(), profile: vGoogleProfile });

type Details = { name?: string; email?: string; emailVerified: boolean };

/**
 * Keeps the user's name and email up to date from what Apple or Google sent. The
 * email is how Walkies will reach people later, so it's refreshed on every sign-in.
 * Apple only sends the name the first time, so an empty one never wipes a saved one.
 */
async function saveDetails(ctx: MutationCtx, userId: Id<"users">, details: Details) {
  const user = await ctx.db.get("users", userId);
  if (user === null) return;
  await ctx.db.patch("users", userId, {
    name: user.name ?? details.name,
    email: details.email ?? user.email,
    emailVerified: details.email === undefined ? user.emailVerified : details.emailVerified,
  });
}

export const createUserApple = internalMutation({
  args: { provider: vApple },
  returns: v.id("users"),
  handler: async (ctx, { provider: { profile } }) => {
    return await ctx.db.insert("users", { name: profile.name, email: profile.email, emailVerified: profile.emailVerified });
  },
});

export const onSignInApple = internalMutation({
  args: { provider: vApple, userId: v.id("users") },
  returns: v.null(),
  handler: async (ctx, { provider: { profile }, userId }) => {
    await saveDetails(ctx, userId, profile);
    return null;
  },
});

export const createUserGoogle = internalMutation({
  args: { provider: vGoogle },
  returns: v.id("users"),
  handler: async (ctx, { provider: { profile } }) => {
    return await ctx.db.insert("users", {
      name: profile.name,
      email: profile.email,
      emailVerified: profile.emailVerified,
      picture: profile.picture,
    });
  },
});

export const onSignInGoogle = internalMutation({
  args: { provider: vGoogle, userId: v.id("users") },
  returns: v.null(),
  handler: async (ctx, { provider: { profile }, userId }) => {
    await saveDetails(ctx, userId, profile);
    return null;
  },
});

/** The signed-in user's name and email, or null when signed out. */
export const me = query({
  args: {},
  returns: v.union(v.null(), v.object({ name: v.union(v.string(), v.null()), email: v.union(v.string(), v.null()) })),
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (userId === null) return null;
    const user = await ctx.db.get("users", userId);
    if (user === null) return null;
    return { name: user.name ?? null, email: user.email ?? null };
  },
});

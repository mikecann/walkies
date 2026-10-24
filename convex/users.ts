import { ConvexError, v } from "convex/values";
import { getAuthUserId } from "@convex-dev/auth/server";
import { vAppleProfile } from "@convex-dev/auth/methods/apple/server";
import { vGoogleProfile } from "@convex-dev/auth/methods/google/server";
import { env, internalMutation, mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { deletionInProgress, startDeletion } from "./accountDeletion";
import { mergeLedgers, parseLedger } from "./progression";
import type { Id } from "./_generated/dataModel";

const vApple = v.object({ name: v.literal("apple"), accountId: v.string(), profile: vAppleProfile });
const vGoogle = v.object({ name: v.literal("google"), accountId: v.string(), profile: vGoogleProfile });

type Details = { name?: string; email?: string; emailVerified: boolean; picture?: string };

export const createUserAnonymous = internalMutation({
  args: { provider: v.object({ name: v.literal("anonymous"), accountId: v.string(), profile: v.object({}) }) },
  returns: v.id("users"),
  handler: async (ctx) => {
    // Every anonymous sign-in calls this, including direct calls that bypass the
    // app's test wrapper. Refuse before a user or session can be created.
    if (env.WALKIES_TEST_SIGNIN !== "1") {
      throw new ConvexError("Test sign-in is disabled on this deployment.");
    }
    const suffix = crypto.randomUUID().slice(0, 4).toUpperCase();
    return await ctx.db.insert("users", { name: `Test walker ${suffix}` });
  },
});

/**
 * Who's signed in: the user their session belongs to, or the one that user was
 * merged into. Use this rather than getAuthUserId everywhere. A deleted account
 * counts as signed out, so every session it had stops working straight away.
 */
export async function currentUserId(ctx: QueryCtx | MutationCtx): Promise<Id<"users"> | null> {
  const userId = await getAuthUserId(ctx);
  if (userId === null) return null;
  const user = await ctx.db.get("users", userId);
  if (user === null) return null;
  const owner = user.mergedInto ? await ctx.db.get("users", user.mergedInto) : user;
  if (owner === null || owner.deletedAt !== undefined) return null;
  return owner._id;
}

/**
 * Someone who's already signed in with this email. Apple and Google both vouch for
 * the address, so signing in the other way gets you the same account. Only for
 * verified emails on both sides, or anyone could claim an address and get in.
 */
async function existingUser(ctx: MutationCtx, details: Details): Promise<Id<"users"> | null> {
  if (!details.email || !details.emailVerified) return null;
  const matches = await ctx.db
    .query("users")
    .withIndex("by_email", (q) => q.eq("email", details.email))
    .collect();
  return matches.find((user) => user.emailVerified && user.mergedInto === undefined)?._id ?? null;
}

/**
 * Keeps the user's name and email up to date from what Apple or Google sent. The
 * email is how Walkies will reach people later, so it's refreshed on every sign-in.
 * Apple only sends the name the first time, so an empty one never wipes a saved one.
 * Google's photo is kept current, and given to an account first made with Apple.
 */
async function saveDetails(ctx: MutationCtx, userId: Id<"users">, details: Details) {
  await reviveIfDeleted(ctx, userId);
  // A user merged into another signs in as that one (currentUserId), so the details
  // go there. Otherwise users:me shows the other row, still empty if it was deleted.
  const user = await ctx.db.get("users", userId);
  const owner = user?.mergedInto ? await ctx.db.get("users", user.mergedInto) : user;
  if (!owner) return;
  await ctx.db.patch("users", owner._id, {
    name: owner.name ?? details.name,
    email: details.email ?? owner.email,
    emailVerified: details.email === undefined ? owner.emailVerified : details.emailVerified,
    picture: details.picture || owner.picture,
  });
}

/**
 * Someone who deleted their account is signing in again with the same Apple or
 * Google account. Convex Auth still points that account at their old, emptied user,
 * so it comes back as a fresh, empty account once the old data has finished going.
 */
async function reviveIfDeleted(ctx: MutationCtx, userId: Id<"users">) {
  const user = await ctx.db.get("users", userId);
  if (user === null) throw new ConvexError({ code: "unknownUser", message: "That account doesn't exist any more." });
  const owner = user.mergedInto ? await ctx.db.get("users", user.mergedInto) : user;
  const deleted = [...new Set([user, owner])].filter((u) => u !== null && u.deletedAt !== undefined) as NonNullable<typeof user>[];
  for (const u of deleted) {
    if (await deletionInProgress(ctx, u._id)) {
      throw new ConvexError({
        code: "accountDeleting",
        message: "Your old account is still being deleted. Give it a few minutes and try again.",
      });
    }
  }
  for (const u of deleted) await ctx.db.patch("users", u._id, { deletedAt: undefined });
}

export const createUserApple = internalMutation({
  args: { provider: vApple },
  returns: v.id("users"),
  handler: async (ctx, { provider: { profile } }) => {
    return (
      (await existingUser(ctx, profile)) ??
      (await ctx.db.insert("users", { name: profile.name, email: profile.email, emailVerified: profile.emailVerified }))
    );
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
    return (
      (await existingUser(ctx, profile)) ??
      (await ctx.db.insert("users", {
        name: profile.name,
        email: profile.email,
        emailVerified: profile.emailVerified,
        picture: profile.picture,
      }))
    );
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

/** The signed-in user's name, email and Google photo, or null when signed out. */
export const me = query({
  args: {},
  returns: v.union(v.null(), v.object({
    name: v.union(v.string(), v.null()), email: v.union(v.string(), v.null()), picture: v.union(v.string(), v.null()),
  })),
  handler: async (ctx) => {
    const userId = await currentUserId(ctx);
    if (userId === null) return null;
    const user = await ctx.db.get("users", userId);
    if (user === null) return null;
    return { name: user.name ?? null, email: user.email ?? null, picture: user.picture ?? null };
  },
});

/**
 * Deletes the signed-in person's account (App Store Guideline 5.1.1(v)). They're
 * signed out straight away: the user row loses its name, email and photo and becomes
 * a tombstone every session treats as signed out (currentUserId). Their walks, places,
 * progress, secrets, team memberships and Chef requests are then deleted in the
 * background (accountDeletion.ts). The app wipes its own copy and calls auth:signOut.
 * Convex Auth v2 keeps no Apple or Google tokens to revoke, and its own account and
 * session rows (in its components) only point at the tombstone.
 */
export const deleteAccount = mutation({
  args: {},
  returns: v.object({ deletionId: v.id("accountDeletions") }),
  handler: async (ctx) => {
    const userId = await currentUserId(ctx);
    if (userId === null) throw new ConvexError({ code: "UNAUTHENTICATED", message: "Sign in first." });
    const scrub = { deletedAt: Date.now(), name: undefined, email: undefined, emailVerified: undefined, picture: undefined };
    await ctx.db.patch("users", userId, scrub);
    // Older user rows folded into this one (the same person through the other provider).
    // Merging moved their data across, but anything still filed under them goes too.
    const merged = await ctx.db.query("users").withIndex("by_mergedInto", (q) => q.eq("mergedInto", userId)).collect();
    for (const m of merged) {
      await ctx.db.patch("users", m._id, scrub);
      await startDeletion(ctx, m._id);
    }
    return { deletionId: await startDeletion(ctx, userId) };
  },
});

/**
 * Folds together users that share a verified email, made before sign-ins were
 * linked: the oldest keeps everything and the others point at it. Safe to run
 * again. `npx convex run users:mergeDuplicateUsers --prod`
 */
export const mergeDuplicateUsers = internalMutation({
  args: {},
  returns: v.object({ merged: v.number() }),
  handler: async (ctx) => {
    const users = await ctx.db.query("users").collect();
    const byEmail = new Map<string, typeof users>();
    for (const user of users) {
      if (!user.email || !user.emailVerified || user.mergedInto !== undefined) continue;
      byEmail.set(user.email, [...(byEmail.get(user.email) ?? []), user]);
    }
    let merged = 0;
    for (const group of byEmail.values()) {
      if (group.length < 2) continue;
      const [keep, ...rest] = group.sort((a, b) => a._creationTime - b._creationTime);
      for (const dup of rest) {
        await moveData(ctx, dup._id, keep._id);
        await ctx.db.patch("users", dup._id, { mergedInto: keep._id });
        await ctx.db.patch("users", keep._id, { picture: keep.picture ?? dup.picture, name: keep.name ?? dup.name });
        merged++;
      }
    }
    return { merged };
  },
});

/** Hands one user's walks, places and secrets to another, skipping any they already have. */
async function moveData(ctx: MutationCtx, from: Id<"users">, to: Id<"users">) {
  // Keep the canonical membership when both accounts already belong to a team.
  for (const member of await ctx.db.query("teamMembers").withIndex("by_user", (q) => q.eq("userId", from)).collect()) {
    const keep = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", member.teamId).eq("userId", to)).unique();
    if (keep !== null) await ctx.db.delete("teamMembers", member._id);
    else await ctx.db.patch("teamMembers", member._id, { userId: to });
  }
  for (const team of await ctx.db.query("teams").withIndex("by_creator", (q) => q.eq("createdBy", from)).collect()) await ctx.db.patch("teams", team._id, { createdBy: to });
  for (const removal of await ctx.db.query("teamRemovals").withIndex("by_user", (q) => q.eq("userId", from)).collect()) {
    const keep = await ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", removal.teamId).eq("userId", to)).unique();
    if (keep === null) await ctx.db.patch("teamRemovals", removal._id, { userId: to });
    else { await ctx.db.patch("teamRemovals", keep._id, { epoch: Math.max(keep.epoch, removal.epoch) }); await ctx.db.delete("teamRemovals", removal._id); }
  }

  const attempts = await ctx.db.query("teamInviteAttempts").withIndex("by_user", (q) => q.eq("userId", from)).unique();
  if (attempts !== null) {
    const keep = await ctx.db.query("teamInviteAttempts").withIndex("by_user", (q) => q.eq("userId", to)).unique();
    if (keep === null) await ctx.db.patch("teamInviteAttempts", attempts._id, { userId: to });
    else {
      const hour = 60 * 60 * 1000, now = Date.now();
      const active = [attempts, keep].filter((row) => now < row.windowStart + hour);
      await ctx.db.patch("teamInviteAttempts", keep._id, { windowStart: Math.max(0, ...active.map((row) => row.windowStart)), count: Math.min(30, active.reduce((sum, row) => sum + row.count, 0)) });
      await ctx.db.delete("teamInviteAttempts", attempts._id);
    }
  }
  const progress = await ctx.db.query("progress").withIndex("by_user", (q) => q.eq("userId", from)).unique();
  if (progress !== null) {
    const keep = await ctx.db.query("progress").withIndex("by_user", (q) => q.eq("userId", to)).unique();
    if (keep === null) await ctx.db.patch("progress", progress._id, { userId: to });
    else {
      const ledger = mergeLedgers(parseLedger(keep.ledger), parseLedger(progress.ledger));
      await ctx.db.patch("progress", keep._id, { ledger: JSON.stringify(ledger), updatedAt: Math.max(keep.updatedAt, progress.updatedAt) });
      await ctx.db.delete("progress", progress._id);
    }
  }
  for (const walk of await ctx.db.query("walks").withIndex("by_user_client", (q) => q.eq("userId", from)).collect()) {
    const has = await ctx.db.query("walks").withIndex("by_user_client", (q) => q.eq("userId", to).eq("clientId", walk.clientId)).unique();
    if (has === null) await ctx.db.patch("walks", walk._id, { userId: to });
    else await ctx.db.delete("walks", walk._id);
  }
  for (const place of await ctx.db.query("places").withIndex("by_user_client", (q) => q.eq("userId", from)).collect()) {
    const has = await ctx.db.query("places").withIndex("by_user_client", (q) => q.eq("userId", to).eq("clientId", place.clientId)).unique();
    if (has === null) await ctx.db.patch("places", place._id, { userId: to });
    else if (place.updatedAt > has.updatedAt) {
      await ctx.db.delete("places", has._id);
      await ctx.db.patch("places", place._id, { userId: to });
    } else await ctx.db.delete("places", place._id);
  }
  for (const secret of await ctx.db.query("secrets").withIndex("by_user_secret", (q) => q.eq("userId", from)).collect()) {
    const has = await ctx.db.query("secrets").withIndex("by_user_secret", (q) => q.eq("userId", to).eq("secretId", secret.secretId)).unique();
    if (has === null) await ctx.db.patch("secrets", secret._id, { userId: to });
    else {
      if (secret.foundAt < has.foundAt) await ctx.db.patch("secrets", has._id, { foundAt: secret.foundAt });
      await ctx.db.delete("secrets", secret._id);
    }
  }
}

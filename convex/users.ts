import { ConvexError, v } from "convex/values";
import { getAuthUserId } from "@convex-dev/auth/server";
import { vAppleProfile } from "@convex-dev/auth/methods/apple/server";
import { vGoogleProfile } from "@convex-dev/auth/methods/google/server";
import { env, internalMutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { mergeLedgers, parseLedger } from "./progression";
import { deleteMemberTrails } from "./teams";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";

const vApple = v.object({ name: v.literal("apple"), accountId: v.string(), profile: vAppleProfile });
const vGoogle = v.object({ name: v.literal("google"), accountId: v.string(), profile: vGoogleProfile });

type Details = { name?: string; email?: string; emailVerified: boolean };

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
 * merged into. Use this rather than getAuthUserId everywhere.
 */
export async function currentUserId(ctx: QueryCtx | MutationCtx): Promise<Id<"users"> | null> {
  const userId = await getAuthUserId(ctx);
  if (userId === null) return null;
  const user = await ctx.db.get("users", userId);
  return user?.mergedInto ?? userId;
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

/** The signed-in user's name and email, or null when signed out. */
export const me = query({
  args: {},
  returns: v.union(v.null(), v.object({ name: v.union(v.string(), v.null()), email: v.union(v.string(), v.null()) })),
  handler: async (ctx) => {
    const userId = await currentUserId(ctx);
    if (userId === null) return null;
    const user = await ctx.db.get("users", userId);
    if (user === null) return null;
    return { name: user.name ?? null, email: user.email ?? null };
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

// Large city grids can exceed a mutation's read limit. Resolve membership and
// privacy in the merge transaction, then drain attribution in bounded batches.
async function moveTeamCreditsBatch(ctx: MutationCtx, from: Id<"users">, to: Id<"users">) {
  const tiles = await ctx.db.query("teamTiles").withIndex("by_user", (q) => q.eq("by", from)).take(500);
  const secrets = await ctx.db.query("teamSecrets").withIndex("by_user", (q) => q.eq("by", from)).take(500);
  const clocks = new Map<Id<"teams">, number>();
  for (const tile of tiles) {
    let receivedAt = clocks.get(tile.teamId);
    if (receivedAt === undefined) {
      const team = await ctx.db.get("teams", tile.teamId);
      if (team !== null) { receivedAt = Math.max(Date.now(), team.tilesUpdatedAt + 1); clocks.set(tile.teamId, receivedAt); }
    }
    // Attribution changes must reach phones that already cached the tile too.
    await ctx.db.patch("teamTiles", tile._id, { by: to, ...(receivedAt === undefined ? {} : { receivedAt }) });
  }
  for (const [teamId, tilesUpdatedAt] of clocks) await ctx.db.patch("teams", teamId, { tilesUpdatedAt });
  for (const secret of secrets) await ctx.db.patch("teamSecrets", secret._id, { by: to });
  if (tiles.length === 500 || secrets.length === 500) await ctx.scheduler.runAfter(0, internal.users.moveTeamCredits, { from, to });
}
export const moveTeamCredits = internalMutation({
  args: { from: v.id("users"), to: v.id("users") }, returns: v.null(),
  handler: async (ctx, { from, to }) => { await moveTeamCreditsBatch(ctx, from, to); return null; },
});

/** Hands one user's walks, places and secrets to another, skipping any they already have. */
async function moveData(ctx: MutationCtx, from: Id<"users">, to: Id<"users">) {
  // Preserve the canonical membership's privacy choices. If both accounts were
  // members, discard the duplicate's routes instead of broadening consent.
  for (const member of await ctx.db.query("teamMembers").withIndex("by_user", (q) => q.eq("userId", from)).collect()) {
    const keep = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", member.teamId).eq("userId", to)).unique();
    if (keep !== null) {
      await deleteMemberTrails(ctx, { teamId: member.teamId, userId: from, memberId: member._id, epoch: member.trailEpoch ?? 0 });
      await ctx.db.delete("teamMembers", member._id);
    } else {
      await ctx.db.patch("teamMembers", member._id, { userId: to });
      if (member.sharing === "tilesAndTrail") {
        const epoch = member.trailEpoch ?? 0;
        const tagged = await ctx.db.query("teamTrails").withIndex("by_cleanup", (q) => q.eq("teamId", member.teamId).eq("userId", from).eq("memberId", member._id).eq("epoch", epoch)).take(64);
        const legacy = epoch === 0 ? await ctx.db.query("teamTrails").withIndex("by_cleanup", (q) => q.eq("teamId", member.teamId).eq("userId", from).eq("memberId", undefined)).take(64) : [];
        const trails = [...tagged, ...legacy.filter((trail) => trail._creationTime >= member._creationTime)].slice(0, 64);
        for (const trail of trails) await ctx.db.patch("teamTrails", trail._id, { userId: to, memberId: member._id, epoch });
      }
      // Also drain any pre-cap legacy excess in bounded transactions.
      await deleteMemberTrails(ctx, { teamId: member.teamId, userId: from, memberId: member._id, epoch: member.trailEpoch ?? 0 });
    }
  }
  for (const team of await ctx.db.query("teams").withIndex("by_creator", (q) => q.eq("createdBy", from)).collect()) await ctx.db.patch("teams", team._id, { createdBy: to });
  for (const place of await ctx.db.query("teamPlaces").withIndex("by_added", (q) => q.eq("addedBy", from)).collect()) await ctx.db.patch("teamPlaces", place._id, { addedBy: to });
  await moveTeamCreditsBatch(ctx, from, to);
  for (const upload of await ctx.db.query("teamUploads").withIndex("by_user", (q) => q.eq("userId", from)).collect()) await ctx.db.patch("teamUploads", upload._id, { userId: to });
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

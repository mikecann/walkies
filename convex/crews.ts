import { ConvexError, v } from "convex/values";
import { internalMutation, internalQuery, mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { currentUserId } from "./users";

const sharing = v.union(v.literal("tiles"), v.literal("tilesAndTrail"));
const nullableUrl = v.union(v.string(), v.null());
const inviteAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const memberInfo = v.object({
  userId: v.id("users"), name: v.string(), colour: v.string(), sharing,
  walksCount: v.boolean(), joinedAt: v.number(), isYou: v.boolean(),
});
const crewInfo = v.object({
  crewId: v.id("crews"), name: v.string(), createdBy: v.id("users"),
  inviteCode: v.string(), createdAt: v.number(),
});

type ReadCtx = QueryCtx | MutationCtx;
function fail(code: string, message: string): never {
  throw new ConvexError({ code, message });
}
function text(value: string, label: string, max = 100) {
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > max) fail("INVALID_ARGUMENT", `${label} must contain 1–${max} characters.`);
  return trimmed;
}
function finite(value: number, label: string) {
  if (!Number.isFinite(value)) fail("INVALID_ARGUMENT", `${label} must be finite.`);
}
async function requireUser(ctx: ReadCtx) {
  const userId = await currentUserId(ctx);
  if (userId === null || await ctx.db.get("users", userId) === null) fail("UNAUTHENTICATED", "Sign in to use crew maps.");
  return userId;
}
async function requireMember(ctx: ReadCtx, crewId: Id<"crews">) {
  const userId = await requireUser(ctx);
  const member = await ctx.db.query("crewMembers")
    .withIndex("by_crew_user", (q) => q.eq("crewId", crewId).eq("userId", userId)).unique();
  // Do not reveal whether a crew exists to someone outside it.
  if (member === null) fail("NOT_A_MEMBER", "You are not a member of this crew map.");
  const crew = await ctx.db.get("crews", crewId);
  if (crew === null) fail("CREW_NOT_FOUND", "This crew map no longer exists.");
  return { userId, member, crew };
}
async function requireCreator(ctx: ReadCtx, crewId: Id<"crews">) {
  const access = await requireMember(ctx, crewId);
  if (access.crew.createdBy !== access.userId) fail("CREATOR_ONLY", "Only the crew's creator can do that.");
  return access;
}
async function memberName(ctx: ReadCtx, userId: Id<"users">, name?: string) {
  if (name !== undefined) return text(name, "Your name");
  const user = await ctx.db.get("users", userId);
  return user?.name?.trim() || "Explorer";
}
async function findInvite(ctx: ReadCtx, code: string) {
  const normalized = code.trim().toUpperCase();
  if (normalized.length !== 6 || [...normalized].some((c) => !inviteAlphabet.includes(c))) return null;
  return await ctx.db.query("crews").withIndex("by_invite", (q) => q.eq("inviteCode", normalized)).unique();
}
async function requireFile(ctx: MutationCtx, file: Id<"_storage">) {
  if (await ctx.db.system.get("_storage", file) === null) fail("FILE_NOT_FOUND", "Upload the crew JSON file before saving it.");
}
async function deleteTrails(ctx: MutationCtx, crewId: Id<"crews">, userId: Id<"users">) {
  const trails = await ctx.db.query("crewTrails")
    .withIndex("by_crew_user_walk", (q) => q.eq("crewId", crewId).eq("userId", userId)).collect();
  for (const trail of trails) {
    await ctx.db.delete("crewTrails", trail._id);
    await ctx.storage.delete(trail.file);
  }
}
async function removeMembership(ctx: MutationCtx, crewId: Id<"crews">, userId: Id<"users">) {
  const member = await ctx.db.query("crewMembers")
    .withIndex("by_crew_user", (q) => q.eq("crewId", crewId).eq("userId", userId)).unique();
  if (member === null) return;
  await deleteTrails(ctx, crewId, userId);
  await ctx.db.delete("crewMembers", member._id);
  const remaining = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crewId)).first();
  if (remaining !== null) return; // Tiles and secret credits remain as history while anyone is here.
  // Revoke access and the invite immediately; large maps are drained in bounded
  // transactions so leaving does not exceed Convex's document/write limits.
  await ctx.db.delete("crews", crewId);
  await deleteCrewDataBatch(ctx, crewId);
}

async function deleteCrewDataBatch(ctx: MutationCtx, crewId: Id<"crews">) {
  const batchSize = 500;
  const [places, tiles, trails, secrets] = await Promise.all([
    ctx.db.query("crewPlaces").withIndex("by_crew_client", (q) => q.eq("crewId", crewId)).take(batchSize),
    ctx.db.query("crewTiles").withIndex("by_crew_received", (q) => q.eq("crewId", crewId)).take(batchSize),
    ctx.db.query("crewTrails").withIndex("by_crew_user_walk", (q) => q.eq("crewId", crewId)).take(batchSize),
    ctx.db.query("crewSecrets").withIndex("by_crew_secret", (q) => q.eq("crewId", crewId)).take(batchSize),
  ]);
  for (const place of places) {
    await ctx.db.delete("crewPlaces", place._id);
    await ctx.storage.delete(place.file);
  }
  for (const tile of tiles) {
    await ctx.db.delete("crewTiles", tile._id);
  }
  for (const trail of trails) {
    await ctx.db.delete("crewTrails", trail._id);
    await ctx.storage.delete(trail.file);
  }
  for (const secret of secrets) {
    await ctx.db.delete("crewSecrets", secret._id);
  }
  if ([places, tiles, trails, secrets].some((rows) => rows.length === batchSize)) {
    await ctx.scheduler.runAfter(0, internal.crews.cleanupEmptyCrew, { crewId });
  }
}

/** Continues final-departure cleanup. Internal only; a live crew is never touched. */
export const cleanupEmptyCrew = internalMutation({
  args: { crewId: v.id("crews") }, returns: v.null(),
  handler: async (ctx, { crewId }) => {
    if (await ctx.db.get("crews", crewId) === null) await deleteCrewDataBatch(ctx, crewId);
    return null;
  },
});

/** Create a crew and its first membership. Walks count by default. */
export const createCrew = mutation({
  args: { name: v.string(), colour: v.string(), sharing },
  returns: v.object({ crewId: v.id("crews"), inviteCode: v.string() }),
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const name = text(args.name, "Crew name");
    const colour = text(args.colour, "Colour", 64);
    // The indexed read participates in Convex's transaction conflict detection,
    // so even concurrent creators cannot commit the same invite code.
    let inviteCode = "";
    for (let attempt = 0; attempt < 10; attempt++) {
      const candidate = Array.from({ length: 6 }, () => inviteAlphabet[Math.floor(Math.random() * inviteAlphabet.length)]).join("");
      if (await findInvite(ctx, candidate) === null) { inviteCode = candidate; break; }
    }
    if (!inviteCode) fail("INVITE_CODE_EXHAUSTED", "Could not create an invite code. Please try again.");
    const now = Date.now();
    const crewId = await ctx.db.insert("crews", { name, createdBy: userId, inviteCode, createdAt: now, tilesUpdatedAt: now });
    await ctx.db.insert("crewMembers", {
      crewId, userId, name: await memberName(ctx, userId), colour,
      sharing: args.sharing, walksCount: true, joinedAt: now,
    });
    return { crewId, inviteCode };
  },
});

/** Signed-in invite preview; deliberately available before becoming a member. */
export const crewForInvite = query({
  args: { code: v.string() },
  returns: v.union(v.null(), v.object({ name: v.string(), memberNames: v.array(v.string()) })),
  handler: async (ctx, { code }) => {
    await requireUser(ctx);
    const crew = await findInvite(ctx, code);
    if (crew === null) return null;
    const members = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crew._id)).collect();
    return { name: crew.name, memberNames: members.map((m) => m.name) };
  },
});

/** Public landing pages get only the crew name, never the member list. */
export const inviteForPage = internalQuery({
  args: { code: v.string() },
  returns: v.union(v.null(), v.object({ name: v.string(), code: v.string() })),
  handler: async (ctx, { code }) => {
    const crew = await findInvite(ctx, code);
    return crew === null ? null : { name: crew.name, code: crew.inviteCode };
  },
});

/** Safe to retry: joining again returns the crew without changing your settings. */
export const joinCrew = mutation({
  args: { code: v.string(), colour: v.string(), sharing, name: v.optional(v.string()) },
  returns: v.id("crews"),
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const crew = await findInvite(ctx, args.code);
    if (crew === null) fail("INVALID_INVITE", "This invite code does not match a crew map.");
    const existing = await ctx.db.query("crewMembers")
      .withIndex("by_crew_user", (q) => q.eq("crewId", crew._id).eq("userId", userId)).unique();
    if (existing === null) await ctx.db.insert("crewMembers", {
      crewId: crew._id, userId, name: await memberName(ctx, userId, args.name),
      colour: text(args.colour, "Colour", 64), sharing: args.sharing, walksCount: true, joinedAt: Date.now(),
    });
    return crew._id;
  },
});

/** Trails are erased immediately when opting out; re-enabling needs a phone replay. */
export const updateMembership = mutation({
  args: { crewId: v.id("crews"), colour: v.optional(v.string()), sharing: v.optional(sharing), walksCount: v.optional(v.boolean()) },
  returns: v.null(),
  handler: async (ctx, args) => {
    const { member, userId } = await requireMember(ctx, args.crewId);
    await ctx.db.patch("crewMembers", member._id, {
      ...(args.colour === undefined ? {} : { colour: text(args.colour, "Colour", 64) }),
      ...(args.sharing === undefined ? {} : { sharing: args.sharing }),
      ...(args.walksCount === undefined ? {} : { walksCount: args.walksCount }),
    });
    if (args.sharing === "tiles") await deleteTrails(ctx, args.crewId, userId);
    return null;
  },
});

/** Leave and erase your trails. The final departure deletes the whole crew. */
export const leaveCrew = mutation({
  args: { crewId: v.id("crews") }, returns: v.null(),
  handler: async (ctx, { crewId }) => {
    const { userId } = await requireMember(ctx, crewId);
    await removeMembership(ctx, crewId, userId);
    return null;
  },
});

export const renameCrew = mutation({
  args: { crewId: v.id("crews"), name: v.string() }, returns: v.null(),
  handler: async (ctx, { crewId, name }) => {
    await requireCreator(ctx, crewId);
    await ctx.db.patch("crews", crewId, { name: text(name, "Crew name") });
    return null;
  },
});

/** Creator only; removing yourself has the same semantics as leaving. */
export const removeMember = mutation({
  args: { crewId: v.id("crews"), userId: v.id("users") }, returns: v.null(),
  handler: async (ctx, { crewId, userId }) => {
    await requireCreator(ctx, crewId);
    await removeMembership(ctx, crewId, userId);
    return null;
  },
});

/**
 * Add immutable place JSON, idempotent by crew + clientId. Returns the server
 * placeId used by tile uploads. Replays must reuse the same clientId. All places
 * use the first place's hex grid; preparing/checking that JSON is the phone's job.
 */
export const addCrewPlace = mutation({
  args: { crewId: v.id("crews"), clientId: v.string(), name: v.string(), file: v.id("_storage") },
  returns: v.id("crewPlaces"),
  handler: async (ctx, args) => {
    const { userId } = await requireMember(ctx, args.crewId);
    const clientId = text(args.clientId, "Place id", 200);
    const existing = await ctx.db.query("crewPlaces")
      .withIndex("by_crew_client", (q) => q.eq("crewId", args.crewId).eq("clientId", clientId)).unique();
    if (existing !== null) return existing._id;
    await requireFile(ctx, args.file);
    return await ctx.db.insert("crewPlaces", {
      ...args, clientId, name: text(args.name, "Place name"), addedBy: userId, updatedAt: Date.now(),
    });
  },
});

/**
 * Up to 1,000 axial [q,r] pairs per call. First committed upload wins, even if a
 * later replay carries an earlier discovery time. Duplicate pairs are harmless.
 */
export const uploadCrewTiles = mutation({
  args: { crewId: v.id("crews"), placeId: v.id("crewPlaces"), hexes: v.array(v.array(v.number())), at: v.number() },
  returns: v.number(),
  handler: async (ctx, { crewId, placeId, hexes, at }) => {
    const { userId, crew } = await requireMember(ctx, crewId);
    const place = await ctx.db.get("crewPlaces", placeId);
    if (place === null || place.crewId !== crewId) fail("PLACE_NOT_FOUND", "This place is not part of this crew map.");
    finite(at, "Discovery time");
    if (hexes.length > 1000 || hexes.some((h) => h.length !== 2 || !h.every(Number.isSafeInteger))) {
      fail("INVALID_ARGUMENT", "Send at most 1,000 hexes, each an integer [q, r] pair.");
    }
    // Persist the clock so cursors remain safe even when several uploads and
    // snapshots happen in one millisecond. Do not filter by the phone's `at`.
    const receivedAt = Math.max(Date.now(), crew.tilesUpdatedAt + 1);
    let added = 0;
    for (const [rawQ, rawR] of hexes) {
      // Convex indexes distinguish -0 from 0, but axial coordinates don't.
      const q = rawQ === 0 ? 0 : rawQ;
      const r = rawR === 0 ? 0 : rawR;
      const existing = await ctx.db.query("crewTiles").withIndex("by_crew_place_hex", (index) =>
        index.eq("crewId", crewId).eq("placeId", placeId).eq("q", q).eq("r", r)).unique();
      if (existing !== null) continue;
      await ctx.db.insert("crewTiles", { crewId, placeId, q, r, by: userId, at, receivedAt });
      added++;
    }
    if (added > 0) await ctx.db.patch("crews", crewId, { tilesUpdatedAt: receivedAt });
    return added;
  },
});

/** A dedicated route file clipped to crew places. Replaces only your own walk. */
export const uploadCrewTrail = mutation({
  args: { crewId: v.id("crews"), walkClientId: v.string(), file: v.id("_storage") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const { userId, member } = await requireMember(ctx, args.crewId);
    if (member.sharing !== "tilesAndTrail") fail("TRAIL_SHARING_DISABLED", "Enable tiles and trail sharing before uploading a route.");
    const walkClientId = text(args.walkClientId, "Walk id", 200);
    await requireFile(ctx, args.file);
    const existing = await ctx.db.query("crewTrails").withIndex("by_crew_user_walk", (q) =>
      q.eq("crewId", args.crewId).eq("userId", userId).eq("walkClientId", walkClientId)).unique();
    if (existing === null) await ctx.db.insert("crewTrails", { ...args, walkClientId, userId, at: Date.now() });
    else if (existing.file !== args.file) {
      await ctx.db.patch("crewTrails", existing._id, { file: args.file, at: Date.now() });
      await ctx.storage.delete(existing.file);
    }
    return null;
  },
});

/** First committed finder wins; later retries/backfills cannot change the credit. */
export const recordCrewSecrets = mutation({
  args: { crewId: v.id("crews"), secrets: v.array(v.object({ secretId: v.string(), at: v.number() })) },
  returns: v.null(),
  handler: async (ctx, { crewId, secrets }) => {
    const { userId } = await requireMember(ctx, crewId);
    if (secrets.length > 1000) fail("INVALID_ARGUMENT", "Send at most 1,000 secrets per call.");
    for (const secret of secrets) {
      const secretId = text(secret.secretId, "Secret id", 200);
      finite(secret.at, "Discovery time");
      const existing = await ctx.db.query("crewSecrets")
        .withIndex("by_crew_secret", (q) => q.eq("crewId", crewId).eq("secretId", secretId)).unique();
      if (existing === null) await ctx.db.insert("crewSecrets", { crewId, secretId, by: userId, at: secret.at });
    }
    return null;
  },
});

/**
 * Full metadata, places, trails and secrets on every poll. Only tiles are a delta:
 * pass back serverTime as since, merge tiles, and REPLACE the other lists so
 * removals/opt-outs disappear locally. Omit since for the first sync/reset.
 */
export const crewSnapshot = query({
  args: { crewId: v.id("crews"), since: v.optional(v.number()) },
  returns: v.object({
    crew: crewInfo, members: v.array(memberInfo), serverTime: v.number(),
    places: v.array(v.object({ placeId: v.id("crewPlaces"), clientId: v.string(), name: v.string(), updatedAt: v.number(), url: nullableUrl })),
    tiles: v.array(v.object({ placeId: v.id("crewPlaces"), q: v.number(), r: v.number(), by: v.id("users"), at: v.number() })),
    trails: v.array(v.object({ walkClientId: v.string(), url: nullableUrl, by: v.id("users"), at: v.number() })),
    secrets: v.array(v.object({ secretId: v.string(), by: v.id("users"), at: v.number() })),
  }),
  handler: async (ctx, { crewId, since }) => {
    const { userId, crew } = await requireMember(ctx, crewId);
    if (since !== undefined) finite(since, "Snapshot cursor");
    const [members, places, tiles, trails, secrets] = await Promise.all([
      ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crewId)).collect(),
      ctx.db.query("crewPlaces").withIndex("by_crew_client", (q) => q.eq("crewId", crewId)).collect(),
      ctx.db.query("crewTiles").withIndex("by_crew_received", (q) => since === undefined
        ? q.eq("crewId", crewId) : q.eq("crewId", crewId).gt("receivedAt", since)).collect(),
      ctx.db.query("crewTrails").withIndex("by_crew_user_walk", (q) => q.eq("crewId", crewId)).collect(),
      ctx.db.query("crewSecrets").withIndex("by_crew_secret", (q) => q.eq("crewId", crewId)).collect(),
    ]);
    const sharingUsers = new Set(members.filter((m) => m.sharing === "tilesAndTrail").map((m) => m.userId));
    return {
      crew: { crewId, name: crew.name, createdBy: crew.createdBy, inviteCode: crew.inviteCode, createdAt: crew.createdAt },
      serverTime: crew.tilesUpdatedAt,
      members: members.map((m) => ({ userId: m.userId, name: m.name, colour: m.colour, sharing: m.sharing, walksCount: m.walksCount, joinedAt: m.joinedAt, isYou: m.userId === userId })),
      places: await Promise.all(places.map(async (p) => ({ placeId: p._id, clientId: p.clientId, name: p.name, updatedAt: p.updatedAt, url: await ctx.storage.getUrl(p.file) }))),
      tiles: tiles.map((t) => ({ placeId: t.placeId, q: t.q, r: t.r, by: t.by, at: t.at })),
      trails: await Promise.all(trails.filter((t) => sharingUsers.has(t.userId)).map(async (t) => ({ walkClientId: t.walkClientId, url: await ctx.storage.getUrl(t.file), by: t.userId, at: t.at }))),
      secrets: secrets.map((s) => ({ secretId: s.secretId, by: s.by, at: s.at })),
    };
  },
});

/** Crew switcher summary, with the caller's complete membership preferences. */
export const myCrews = query({
  args: {},
  returns: v.array(v.object({ crewId: v.id("crews"), name: v.string(), memberCount: v.number(), membership: memberInfo })),
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const memberships = await ctx.db.query("crewMembers").withIndex("by_user", (q) => q.eq("userId", userId)).collect();
    return await Promise.all(memberships.map(async (m) => {
      const crew = await ctx.db.get("crews", m.crewId);
      if (crew === null) fail("CREW_NOT_FOUND", "This crew map no longer exists.");
      const members = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", m.crewId)).collect();
      return { crewId: crew._id, name: crew.name, memberCount: members.length,
        membership: { userId, name: m.name, colour: m.colour, sharing: m.sharing, walksCount: m.walksCount, joinedAt: m.joinedAt, isYou: true } };
    }));
  },
});

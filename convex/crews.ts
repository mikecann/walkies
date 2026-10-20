import { ConvexError, v } from "convex/values";
import { action, internalMutation, internalQuery, mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { currentUserId } from "./users";

const sharing = v.union(v.literal("tiles"), v.literal("tilesAndTrail"));
const nullableUrl = v.union(v.string(), v.null());
const inviteAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const boundsValidator = v.object({ minQ: v.number(), maxQ: v.number(), minR: v.number(), maxR: v.number() });
const tileCursor = v.object({ position: v.string(), until: v.number(), since: v.union(v.number(), v.null()) });
const memberInfo = v.object({
  userId: v.id("users"), name: v.string(), colour: v.string(), sharing,
  walksCount: v.boolean(), joinedAt: v.number(), isYou: v.boolean(),
});
const crewInfo = v.object({
  crewId: v.id("crews"), name: v.string(), createdBy: v.id("users"),
  inviteCode: v.string(), createdAt: v.number(),
});
const MAX_MEMBERS = 8;
const MAX_PLACES = 16;
const MAX_TILES = 50_000;
const MAX_TRAILS = 64;
const MAX_SECRETS = 1000;
const HOUR = 60 * 60 * 1000;
type ReadCtx = QueryCtx | MutationCtx;
function fail(code: string, message: string): never { throw new ConvexError({ code, message }); }
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
  if (userId === null || await ctx.db.get("users", userId) === null) fail("UNAUTHENTICATED", "Sign in to use team maps.");
  return userId;
}
async function requireMember(ctx: ReadCtx, crewId: Id<"crews">) {
  const userId = await requireUser(ctx);
  const member = await ctx.db.query("crewMembers")
    .withIndex("by_crew_user", (q) => q.eq("crewId", crewId).eq("userId", userId)).unique();
  if (member === null) fail("NOT_A_MEMBER", "You are not a member of this team map.");
  const crew = await ctx.db.get("crews", crewId);
  if (crew === null) fail("CREW_NOT_FOUND", "This team map no longer exists.");
  return { userId, member, crew };
}
async function requireCreator(ctx: ReadCtx, crewId: Id<"crews">) {
  const access = await requireMember(ctx, crewId);
  if (access.crew.createdBy !== access.userId) fail("CREATOR_ONLY", "Only the team's creator can do that.");
  return access;
}
async function memberName(ctx: ReadCtx, userId: Id<"users">, name?: string) {
  if (name !== undefined) return text(name, "Your name");
  return (await ctx.db.get("users", userId))?.name?.trim() || "Explorer";
}
async function findInvite(ctx: ReadCtx, code: string) {
  const normalized = code.trim().toUpperCase();
  if (normalized.length !== 8 || [...normalized].some((c) => !inviteAlphabet.includes(c))) return null;
  return await ctx.db.query("crews").withIndex("by_invite", (q) => q.eq("inviteCode", normalized)).unique();
}
// Crypto entropy is generated in actions, outside deterministic transactions.
// Rejection sampling avoids favouring letters when the alphabet doesn't divide 256.
function inviteCandidates() {
  return Array.from({ length: 10 }, () => {
    let code = "";
    while (code.length < 8) {
      for (const byte of crypto.getRandomValues(new Uint8Array(16))) {
        if (byte < Math.floor(256 / inviteAlphabet.length) * inviteAlphabet.length) code += inviteAlphabet[byte % inviteAlphabet.length];
        if (code.length === 8) break;
      }
    }
    return code;
  });
}
async function availableCode(ctx: MutationCtx, candidates: string[]) {
  for (const code of candidates) if (await findInvite(ctx, code) === null) return code;
  fail("INVITE_CODE_EXHAUSTED", "Could not create an invite code. Please try again.");
}
// Failed lookups must commit before an action throws. Throwing inside this
// transaction would roll back the counter and quietly disable the throttle.
async function attemptInvite(ctx: MutationCtx, code: string, countAll = false) {
  const userId = await requireUser(ctx);
  const attempt = await ctx.db.query("crewInviteAttempts").withIndex("by_user", (q) => q.eq("userId", userId)).unique();
  const now = Date.now();
  const current = attempt !== null && now < attempt.windowStart + HOUR;
  if (current && attempt.count >= 30) return { userId, crew: null, limited: true };
  const crew = await findInvite(ctx, code);
  if (crew === null || countAll) {
    if (attempt === null) await ctx.db.insert("crewInviteAttempts", { userId, windowStart: now, count: 1 });
    else await ctx.db.patch("crewInviteAttempts", attempt._id, { windowStart: current ? attempt.windowStart : now, count: current ? attempt.count + 1 : 1 });
  }
  return { userId, crew, limited: false };
}

async function uploadClaim(ctx: ReadCtx, file: Id<"_storage">) {
  return await ctx.db.query("crewUploads").withIndex("by_file", (q) => q.eq("file", file)).unique();
}
async function consumeFile(ctx: MutationCtx, file: Id<"_storage">, userId: Id<"users">) {
  const claim = await uploadClaim(ctx, file);
  if (claim === null || claim.userId !== userId || claim.used) fail("INVALID_UPLOAD", "Use a fresh team upload belonging to your account.");
  if (await ctx.db.system.get("_storage", file) === null) fail("FILE_NOT_FOUND", "Upload the team JSON file before saving it.");
  await ctx.db.patch("crewUploads", claim._id, { used: true });
}
// Legacy, unclaimed files may have personal/other-crew references. Never delete
// them automatically. All new crew files have exclusive ownership enforced above.
async function deleteOwnedFile(ctx: MutationCtx, file: Id<"_storage">) {
  const claim = await uploadClaim(ctx, file);
  if (claim !== null) {
    await ctx.storage.delete(file);
    await ctx.db.delete("crewUploads", claim._id);
  }
}
async function discardFile(ctx: MutationCtx, file: Id<"_storage">, userId: Id<"users">) {
  const claim = await uploadClaim(ctx, file);
  if (claim?.userId === userId && !claim.used) await deleteOwnedFile(ctx, file);
}
export const discardUpload = internalMutation({
  args: { file: v.id("_storage") }, returns: v.null(),
  handler: async (ctx, { file }) => { await discardFile(ctx, file, await requireUser(ctx)); return null; },
});
export const registerUpload = internalMutation({
  args: { file: v.id("_storage") }, returns: v.null(),
  handler: async (ctx, { file }) => {
    const userId = await requireUser(ctx);
    await ctx.db.insert("crewUploads", { file, userId, used: false });
    await ctx.scheduler.runAfter(24 * HOUR, internal.crews.expireUpload, { file });
    return null;
  },
});
export const expireUpload = internalMutation({
  args: { file: v.id("_storage") }, returns: v.null(),
  handler: async (ctx, { file }) => {
    const claim = await uploadClaim(ctx, file);
    if (claim !== null && !claim.used) await deleteOwnedFile(ctx, file);
    return null;
  },
});
export const uploadFile = action({
  args: { json: v.string() }, returns: v.id("_storage"),
  handler: async (ctx, { json }): Promise<Id<"_storage">> => {
    // Authenticate before storing anything; registerUpload checks again atomically.
    await ctx.runQuery(internal.crews.uploadUser, {});
    const blob = new Blob([json], { type: "application/json" });
    if (blob.size > 2 * 1024 * 1024) fail("INVALID_ARGUMENT", "Team JSON must be at most 2 MiB.");
    try { JSON.parse(json); } catch { fail("INVALID_ARGUMENT", "Upload valid JSON."); }
    const file = await ctx.storage.store(blob);
    try { await ctx.runMutation(internal.crews.registerUpload, { file }); }
    catch (error) { await ctx.storage.delete(file); throw error; }
    return file;
  },
});
// Keeping this internal avoids exposing any new account information.
export const uploadUser = internalQuery({ args: {}, returns: v.id("users"), handler: requireUser });

const cleanupArgs = { crewId: v.id("crews"), userId: v.id("users"), memberId: v.id("crewMembers"), epoch: v.number() };
export async function deleteMemberTrails(ctx: MutationCtx, args: { crewId: Id<"crews">; userId: Id<"users">; memberId: Id<"crewMembers">; epoch: number }) {
  const { crewId, userId, memberId, epoch } = args;
  const tagged = await ctx.db.query("crewTrails").withIndex("by_cleanup", (q) =>
    q.eq("crewId", crewId).eq("userId", userId).eq("memberId", memberId).eq("epoch", epoch)).take(250);
  const legacy = await ctx.db.query("crewTrails").withIndex("by_cleanup", (q) =>
    q.eq("crewId", crewId).eq("userId", userId).eq("memberId", undefined)).take(250);
  for (const trail of [...tagged, ...legacy]) {
    await ctx.db.delete("crewTrails", trail._id);
    await deleteOwnedFile(ctx, trail.file);
  }
  if (tagged.length === 250 || legacy.length === 250) await ctx.scheduler.runAfter(0, internal.crews.cleanupMemberTrails, args);
}
export const cleanupMemberTrails = internalMutation({
  args: cleanupArgs, returns: v.null(),
  handler: async (ctx, args) => { await deleteMemberTrails(ctx, args); return null; },
});
async function removeMembership(ctx: MutationCtx, crewId: Id<"crews">, userId: Id<"users">) {
  const member = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crewId).eq("userId", userId)).unique();
  if (member === null) return;
  await deleteMemberTrails(ctx, { crewId, userId, memberId: member._id, epoch: member.trailEpoch ?? 0 });
  await ctx.db.delete("crewMembers", member._id);
  if (await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crewId)).first() !== null) return;
  await ctx.db.delete("crews", crewId);
  await deleteCrewDataBatch(ctx, crewId);
}
async function deleteCrewDataBatch(ctx: MutationCtx, crewId: Id<"crews">) {
  const [places, tiles, trails, secrets, removals] = await Promise.all([
    ctx.db.query("crewPlaces").withIndex("by_crew_client", (q) => q.eq("crewId", crewId)).take(500),
    ctx.db.query("crewTiles").withIndex("by_crew_received", (q) => q.eq("crewId", crewId)).take(500),
    ctx.db.query("crewTrails").withIndex("by_crew_user_walk", (q) => q.eq("crewId", crewId)).take(500),
    ctx.db.query("crewSecrets").withIndex("by_crew_secret", (q) => q.eq("crewId", crewId)).take(500),
    ctx.db.query("crewRemovals").withIndex("by_crew_user", (q) => q.eq("crewId", crewId)).take(500),
  ]);
  for (const row of [...places, ...trails]) { await ctx.db.delete(row._id); await deleteOwnedFile(ctx, row.file); }
  for (const row of [...tiles, ...secrets, ...removals]) await ctx.db.delete(row._id);
  if ([places, tiles, trails, secrets, removals].some((rows) => rows.length === 500)) await ctx.scheduler.runAfter(0, internal.crews.cleanupEmptyCrew, { crewId });
}
export const cleanupEmptyCrew = internalMutation({
  args: { crewId: v.id("crews") }, returns: v.null(),
  handler: async (ctx, { crewId }) => { if (await ctx.db.get("crews", crewId) === null) await deleteCrewDataBatch(ctx, crewId); return null; },
});

const createArgs = { name: v.string(), colour: v.string(), sharing };
export const createCrew = action({
  args: createArgs, returns: v.object({ crewId: v.id("crews"), inviteCode: v.string() }),
  handler: async (ctx, args): Promise<{ crewId: Id<"crews">; inviteCode: string }> =>
    await ctx.runMutation(internal.crews.createCrewRecord, { ...args, candidates: inviteCandidates() }),
});
export const createCrewRecord = internalMutation({
  args: { ...createArgs, candidates: v.array(v.string()) }, returns: v.object({ crewId: v.id("crews"), inviteCode: v.string() }),
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const name = text(args.name, "Team name"), colour = text(args.colour, "Colour", 64);
    const inviteCode = await availableCode(ctx, args.candidates);
    const now = Date.now();
    const crewId = await ctx.db.insert("crews", { name, createdBy: userId, inviteCode, inviteEpoch: 0, createdAt: now, tilesUpdatedAt: now });
    await ctx.db.insert("crewMembers", { crewId, userId, name: await memberName(ctx, userId), colour, sharing: args.sharing, walksCount: true, joinedAt: now, trailEpoch: 0 });
    return { crewId, inviteCode };
  },
});
export const crewForInvite = mutation({
  args: { code: v.string() }, returns: v.union(v.null(), v.object({ name: v.string(), memberNames: v.array(v.string()) })),
  handler: async (ctx, { code }) => {
    const { userId, crew, limited } = await attemptInvite(ctx, code);
    if (limited) fail("RATE_LIMITED", "Try again after the hourly invite limit resets.");
    if (crew === null) return null;
    const removed = await ctx.db.query("crewRemovals").withIndex("by_crew_user", (q) => q.eq("crewId", crew._id).eq("userId", userId)).unique();
    if (removed?.epoch === (crew.inviteEpoch ?? 0)) return null;
    // Keep the response shape, but don't disclose people's names before joining.
    return { name: crew.name, memberNames: [] };
  },
});
const joinArgs = { code: v.string(), colour: v.string(), sharing, name: v.optional(v.string()) };
export const joinCrew = action({
  args: joinArgs, returns: v.id("crews"),
  handler: async (ctx, args): Promise<Id<"crews">> => {
    const result = await ctx.runMutation(internal.crews.joinCrewRecord, args);
    if (result.error !== undefined) fail(result.error, "This invite is unavailable. Ask the creator for a fresh invite or try again later.");
    return result.crewId!;
  },
});
export const joinCrewRecord = internalMutation({
  args: joinArgs, returns: v.object({ crewId: v.optional(v.id("crews")), error: v.optional(v.string()) }),
  handler: async (ctx, args) => {
    const { userId, crew, limited } = await attemptInvite(ctx, args.code, true);
    if (limited) return { error: "RATE_LIMITED" };
    if (crew === null) return { error: "INVALID_INVITE" };
    const existing = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crew._id).eq("userId", userId)).unique();
    if (existing !== null) return { crewId: crew._id };
    const removed = await ctx.db.query("crewRemovals").withIndex("by_crew_user", (q) => q.eq("crewId", crew._id).eq("userId", userId)).unique();
    if (removed?.epoch === (crew.inviteEpoch ?? 0)) return { error: "MEMBER_REMOVED" };
    const members = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crew._id)).take(MAX_MEMBERS);
    if (members.length >= MAX_MEMBERS) return { error: "CREW_FULL" };
    await ctx.db.insert("crewMembers", { crewId: crew._id, userId, name: await memberName(ctx, userId, args.name), colour: text(args.colour, "Colour", 64), sharing: args.sharing, walksCount: true, joinedAt: Date.now(), trailEpoch: 0 });
    return { crewId: crew._id };
  },
});
export const updateMembership = mutation({
  args: { crewId: v.id("crews"), colour: v.optional(v.string()), sharing: v.optional(sharing), walksCount: v.optional(v.boolean()) }, returns: v.null(),
  handler: async (ctx, args) => {
    const { member, userId } = await requireMember(ctx, args.crewId);
    const optOut = args.sharing === "tiles";
    await ctx.db.patch("crewMembers", member._id, {
      ...(args.colour === undefined ? {} : { colour: text(args.colour, "Colour", 64) }),
      ...(args.sharing === undefined ? {} : { sharing: args.sharing }),
      ...(args.walksCount === undefined ? {} : { walksCount: args.walksCount }),
      ...(optOut ? { trailEpoch: (member.trailEpoch ?? 0) + 1 } : {}),
    });
    if (optOut) await deleteMemberTrails(ctx, { crewId: args.crewId, userId, memberId: member._id, epoch: member.trailEpoch ?? 0 });
    return null;
  },
});
export const leaveCrew = mutation({
  args: { crewId: v.id("crews") }, returns: v.null(),
  handler: async (ctx, { crewId }) => { const { userId } = await requireMember(ctx, crewId); await removeMembership(ctx, crewId, userId); return null; },
});
export const renameCrew = mutation({
  args: { crewId: v.id("crews"), name: v.string() }, returns: v.null(),
  handler: async (ctx, { crewId, name }) => { await requireCreator(ctx, crewId); await ctx.db.patch("crews", crewId, { name: text(name, "Team name") }); return null; },
});
export const removeMember = action({
  args: { crewId: v.id("crews"), userId: v.id("users") }, returns: v.null(),
  handler: async (ctx, args): Promise<null> => await ctx.runMutation(internal.crews.removeMemberRecord, { ...args, candidates: inviteCandidates() }),
});
export const removeMemberRecord = internalMutation({
  args: { crewId: v.id("crews"), userId: v.id("users"), candidates: v.array(v.string()) }, returns: v.null(),
  handler: async (ctx, { crewId, userId, candidates }) => {
    const { userId: creator, crew } = await requireCreator(ctx, crewId);
    const member = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crewId).eq("userId", userId)).unique();
    if (member === null) return null;
    if (userId !== creator) {
      const removal = await ctx.db.query("crewRemovals").withIndex("by_crew_user", (q) => q.eq("crewId", crewId).eq("userId", userId)).unique();
      if (removal === null) await ctx.db.insert("crewRemovals", { crewId, userId, epoch: crew.inviteEpoch ?? 0 });
      else await ctx.db.patch("crewRemovals", removal._id, { epoch: crew.inviteEpoch ?? 0 });
      await ctx.db.patch("crews", crewId, { inviteCode: await availableCode(ctx, candidates) });
    }
    await removeMembership(ctx, crewId, userId);
    return null;
  },
});
export const newInviteCode = action({
  args: { crewId: v.id("crews") }, returns: v.string(),
  handler: async (ctx, args): Promise<string> => await ctx.runMutation(internal.crews.rotateInvite, { ...args, candidates: inviteCandidates() }),
});
export const rotateInvite = internalMutation({
  args: { crewId: v.id("crews"), candidates: v.array(v.string()) }, returns: v.string(),
  handler: async (ctx, { crewId, candidates }) => {
    const { crew } = await requireCreator(ctx, crewId);
    const inviteCode = await availableCode(ctx, candidates);
    await ctx.db.patch("crews", crewId, { inviteCode, inviteEpoch: (crew.inviteEpoch ?? 0) + 1 });
    return inviteCode;
  },
});

const placeArgs = { crewId: v.id("crews"), clientId: v.string(), name: v.string(), file: v.id("_storage"), bounds: boundsValidator, gridPlaceId: v.optional(v.union(v.id("crewPlaces"), v.null())) };
export const addCrewPlace = action({
  args: placeArgs, returns: v.id("crewPlaces"),
  handler: async (ctx, args): Promise<Id<"crewPlaces">> => {
    try { return await ctx.runMutation(internal.crews.addPlaceRecord, args); }
    catch (error) { await ctx.runMutation(internal.crews.discardUpload, { file: args.file }); throw error; }
  },
});
export const addPlaceRecord = internalMutation({
  args: placeArgs, returns: v.id("crewPlaces"),
  handler: async (ctx, args) => {
    const { userId } = await requireMember(ctx, args.crewId);
    const clientId = text(args.clientId, "Place id", 200);
    const existing = await ctx.db.query("crewPlaces").withIndex("by_crew_client", (q) => q.eq("crewId", args.crewId).eq("clientId", clientId)).unique();
    if (existing !== null) { if (existing.file !== args.file) await discardFile(ctx, args.file, userId); return existing._id; }
    const { minQ, maxQ, minR, maxR } = args.bounds;
    if (!Object.values(args.bounds).every((n) => Number.isSafeInteger(n) && Math.abs(n) <= 1_000_000) || minQ > maxQ || minR > maxR || maxQ - minQ > 10_000 || maxR - minR > 10_000) fail("INVALID_ARGUMENT", "Supply a valid, bounded axial grid extent.");
    const places = await ctx.db.query("crewPlaces").withIndex("by_crew_client", (q) => q.eq("crewId", args.crewId)).take(MAX_PLACES);
    if (places.length >= MAX_PLACES) fail("PLACE_LIMIT", "A team can contain at most 16 places.");
    // A first-place upload must still be first when it commits. Later places
    // reference a grid they actually downloaded. No schema or file parsing needed.
    if (args.gridPlaceId !== undefined && (args.gridPlaceId === null ? places.length > 0 : !places.some((p) => p._id === args.gridPlaceId))) {
      fail("GRID_CHANGED", "Refresh the team and rebuild this place on its shared grid.");
    }
    await consumeFile(ctx, args.file, userId);
    return await ctx.db.insert("crewPlaces", { crewId: args.crewId, file: args.file, bounds: args.bounds, clientId, name: text(args.name, "Place name"), addedBy: userId, updatedAt: Date.now(), tileCount: 0 });
  },
});
export const uploadCrewTiles = mutation({
  args: { crewId: v.id("crews"), placeId: v.id("crewPlaces"), hexes: v.array(v.array(v.number())), at: v.number(), discoveredAt: v.optional(v.array(v.number())) }, returns: v.number(),
  handler: async (ctx, { crewId, placeId, hexes, at, discoveredAt }) => {
    const { userId, crew, member } = await requireMember(ctx, crewId);
    if (!member.walksCount) fail("CONTRIBUTIONS_PAUSED", "Resume contributions before sharing discoveries.");
    const place = await ctx.db.get("crewPlaces", placeId);
    if (place === null || place.crewId !== crewId) fail("PLACE_NOT_FOUND", "This place is not part of this team map.");
    finite(at, "Discovery time");
    if (discoveredAt !== undefined && (discoveredAt.length !== hexes.length || discoveredAt.some((time) => !Number.isFinite(time)))) fail("INVALID_ARGUMENT", "Supply one finite discovery time per tile.");
    if (hexes.length > 1000 || hexes.some((h) => h.length !== 2 || !h.every(Number.isSafeInteger))) fail("INVALID_ARGUMENT", "Send at most 1,000 integer [q, r] pairs.");
    if (place.bounds === undefined || place.tileCount === undefined) fail("PLACE_BOUNDS_REQUIRED", "This legacy place needs verified grid bounds before accepting more tiles.");
    const { minQ, maxQ, minR, maxR } = place.bounds;
    if (hexes.some(([q, r]) => q < minQ || q > maxQ || r < minR || r > maxR)) fail("INVALID_ARGUMENT", "Tile coordinates must be inside the place's grid extent.");
    const receivedAt = Math.max(Date.now(), crew.tilesUpdatedAt + 1);
    let added = 0;
    for (const [index, [rawQ, rawR]] of hexes.entries()) {
      const q = rawQ === 0 ? 0 : rawQ, r = rawR === 0 ? 0 : rawR;
      const existing = await ctx.db.query("crewTiles").withIndex("by_crew_place_hex", (index) => index.eq("crewId", crewId).eq("placeId", placeId).eq("q", q).eq("r", r)).unique();
      if (existing !== null) continue;
      if (place.tileCount + added >= MAX_TILES) fail("TILE_LIMIT", "This place has reached its 50,000 tile limit.");
      await ctx.db.insert("crewTiles", { crewId, placeId, q, r, by: userId, at: discoveredAt?.[index] ?? at, receivedAt });
      added++;
    }
    if (added > 0) {
      await ctx.db.patch("crews", crewId, { tilesUpdatedAt: receivedAt });
      await ctx.db.patch("crewPlaces", placeId, { tileCount: place.tileCount + added });
    }
    return added;
  },
});
const trailArgs = { crewId: v.id("crews"), walkClientId: v.string(), file: v.id("_storage"), updatedAt: v.number() };
export const uploadCrewTrail = action({
  args: trailArgs, returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    try { return await ctx.runMutation(internal.crews.uploadTrailRecord, args); }
    catch (error) { await ctx.runMutation(internal.crews.discardUpload, { file: args.file }); throw error; }
  },
});
export const uploadTrailRecord = internalMutation({
  args: trailArgs, returns: v.null(),
  handler: async (ctx, args) => {
    const { userId, member } = await requireMember(ctx, args.crewId);
    if (!member.walksCount) fail("CONTRIBUTIONS_PAUSED", "Resume contributions before sharing a route.");
    if (member.sharing !== "tilesAndTrail") fail("TRAIL_SHARING_DISABLED", "Enable tiles and trail sharing before uploading a route.");
    const walkClientId = text(args.walkClientId, "Walk id", 200);
    finite(args.updatedAt, "Route version");
    const existing = await ctx.db.query("crewTrails").withIndex("by_crew_user_walk", (q) => q.eq("crewId", args.crewId).eq("userId", userId).eq("walkClientId", walkClientId)).unique();
    if (existing?.file === args.file) return null;
    if (existing !== null && args.updatedAt <= (existing.updatedAt ?? 0)) { await discardFile(ctx, args.file, userId); return null; }
    const trails = await ctx.db.query("crewTrails").withIndex("by_crew_user_walk", (q) => q.eq("crewId", args.crewId).eq("userId", userId)).take(MAX_TRAILS);
    if (existing === null && trails.length >= MAX_TRAILS) fail("TRAIL_LIMIT", "A member can share at most 64 trails per team.");
    await consumeFile(ctx, args.file, userId);
    const fields = { file: args.file, at: Date.now(), updatedAt: args.updatedAt, memberId: member._id, epoch: member.trailEpoch ?? 0 };
    if (existing === null) await ctx.db.insert("crewTrails", { crewId: args.crewId, userId, walkClientId, ...fields });
    else { await ctx.db.patch("crewTrails", existing._id, fields); await deleteOwnedFile(ctx, existing.file); }
    return null;
  },
});
export const recordCrewSecrets = mutation({
  args: { crewId: v.id("crews"), secrets: v.array(v.object({ secretId: v.string(), at: v.number() })) }, returns: v.null(),
  handler: async (ctx, { crewId, secrets }) => {
    const { userId, member } = await requireMember(ctx, crewId);
    if (!member.walksCount) fail("CONTRIBUTIONS_PAUSED", "Resume contributions before sharing discoveries.");
    if (secrets.length > 1000) fail("INVALID_ARGUMENT", "Send at most 1,000 secrets per call.");
    let count = (await ctx.db.query("crewSecrets").withIndex("by_crew_secret", (q) => q.eq("crewId", crewId)).take(MAX_SECRETS)).length;
    for (const secret of secrets) {
      const secretId = text(secret.secretId, "Secret id", 200); finite(secret.at, "Discovery time");
      const existing = await ctx.db.query("crewSecrets").withIndex("by_crew_secret", (q) => q.eq("crewId", crewId).eq("secretId", secretId)).unique();
      if (existing === null) {
        if (count >= MAX_SECRETS) fail("SECRET_LIMIT", "A team can contain at most 1,000 secrets.");
        await ctx.db.insert("crewSecrets", { crewId, secretId, by: userId, at: secret.at }); count++;
      }
    }
    return null;
  },
});
export const crewSnapshot = query({
  args: { crewId: v.id("crews"), since: v.optional(v.number()), cursor: v.optional(tileCursor) },
  returns: v.object({
    crew: crewInfo, members: v.array(memberInfo), serverTime: v.number(), cursor: v.union(tileCursor, v.null()), more: v.boolean(),
    places: v.array(v.object({ placeId: v.id("crewPlaces"), clientId: v.string(), name: v.string(), updatedAt: v.number(), url: nullableUrl })),
    tiles: v.array(v.object({ placeId: v.id("crewPlaces"), q: v.number(), r: v.number(), by: v.id("users"), at: v.number() })),
    trails: v.array(v.object({ walkClientId: v.string(), url: nullableUrl, by: v.id("users"), at: v.number() })),
    secrets: v.array(v.object({ secretId: v.string(), by: v.id("users"), at: v.number() })),
  }),
  handler: async (ctx, { crewId, since, cursor }) => {
    const { userId, crew } = await requireMember(ctx, crewId);
    if (since !== undefined) finite(since, "Snapshot cursor");
    if (cursor !== undefined && (cursor.since !== (since ?? null) || !Number.isFinite(cursor.until))) fail("INVALID_ARGUMENT", "Keep since unchanged while paging a snapshot.");
    const until = cursor?.until ?? Math.max(crew.tilesUpdatedAt, since ?? 0);
    const [members, places, tilePage, trails, secrets] = await Promise.all([
      ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crewId)).take(MAX_MEMBERS),
      ctx.db.query("crewPlaces").withIndex("by_crew_client", (q) => q.eq("crewId", crewId)).take(MAX_PLACES),
      ctx.db.query("crewTiles").withIndex("by_crew_received", (q) => since === undefined ? q.eq("crewId", crewId).lte("receivedAt", until) : q.eq("crewId", crewId).gt("receivedAt", since).lte("receivedAt", until)).paginate({ cursor: cursor?.position ?? null, numItems: 1000 }),
      ctx.db.query("crewTrails").withIndex("by_crew_user_walk", (q) => q.eq("crewId", crewId)).take(MAX_MEMBERS * MAX_TRAILS),
      ctx.db.query("crewSecrets").withIndex("by_crew_secret", (q) => q.eq("crewId", crewId)).take(MAX_SECRETS),
    ]);
    const sharingMembers = new Map(members.filter((m) => m.sharing === "tilesAndTrail").map((m) => [m.userId, m]));
    return {
      crew: { crewId, name: crew.name, createdBy: crew.createdBy, inviteCode: crew.inviteCode, createdAt: crew.createdAt },
      serverTime: until, more: !tilePage.isDone,
      cursor: tilePage.isDone ? null : { position: tilePage.continueCursor, until, since: since ?? null },
      members: members.map((m) => ({ userId: m.userId, name: m.name, colour: m.colour, sharing: m.sharing, walksCount: m.walksCount, joinedAt: m.joinedAt, isYou: m.userId === userId })),
      places: await Promise.all(places.map(async (p) => ({ placeId: p._id, clientId: p.clientId, name: p.name, updatedAt: p.updatedAt, url: await ctx.storage.getUrl(p.file) }))),
      tiles: tilePage.page.map((t) => ({ placeId: t.placeId, q: t.q, r: t.r, by: t.by, at: t.at })),
      trails: await Promise.all(trails.filter((t) => {
        const member = sharingMembers.get(t.userId);
        return member !== undefined && (t.memberId === undefined ? (member.trailEpoch ?? 0) === 0 && t._creationTime >= member._creationTime : t.memberId === member._id && t.epoch === (member.trailEpoch ?? 0));
      }).map(async (t) => ({ walkClientId: t.walkClientId, url: await ctx.storage.getUrl(t.file), by: t.userId, at: t.at }))),
      secrets: secrets.map((s) => ({ secretId: s.secretId, by: s.by, at: s.at })),
    };
  },
});
export const myCrews = query({
  args: {}, returns: v.array(v.object({ crewId: v.id("crews"), name: v.string(), memberCount: v.number(), membership: memberInfo })),
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const memberships = await ctx.db.query("crewMembers").withIndex("by_user", (q) => q.eq("userId", userId)).collect();
    return await Promise.all(memberships.map(async (m) => {
      const crew = await ctx.db.get("crews", m.crewId);
      if (crew === null) fail("CREW_NOT_FOUND", "This team map no longer exists.");
      const members = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", m.crewId)).take(MAX_MEMBERS);
      return { crewId: crew._id, name: crew.name, memberCount: members.length, membership: { userId, name: m.name, colour: m.colour, sharing: m.sharing, walksCount: m.walksCount, joinedAt: m.joinedAt, isYou: true } };
    }));
  },
});

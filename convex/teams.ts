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
const teamInfo = v.object({
  teamId: v.id("teams"), name: v.string(), createdBy: v.id("users"),
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
async function requireMember(ctx: ReadCtx, teamId: Id<"teams">) {
  const userId = await requireUser(ctx);
  const member = await ctx.db.query("teamMembers")
    .withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId)).unique();
  if (member === null) fail("NOT_A_MEMBER", "You are not a member of this team map.");
  const team = await ctx.db.get("teams", teamId);
  if (team === null) fail("TEAM_NOT_FOUND", "This team map no longer exists.");
  return { userId, member, team };
}
async function requireCreator(ctx: ReadCtx, teamId: Id<"teams">) {
  const access = await requireMember(ctx, teamId);
  if (access.team.createdBy !== access.userId) fail("CREATOR_ONLY", "Only the team's creator can do that.");
  return access;
}
async function memberName(ctx: ReadCtx, userId: Id<"users">, name?: string) {
  if (name !== undefined) return text(name, "Your name");
  return (await ctx.db.get("users", userId))?.name?.trim() || "Explorer";
}
async function findInvite(ctx: ReadCtx, code: string) {
  const normalized = code.trim().toUpperCase();
  if (normalized.length !== 8 || [...normalized].some((c) => !inviteAlphabet.includes(c))) return null;
  return await ctx.db.query("teams").withIndex("by_invite", (q) => q.eq("inviteCode", normalized)).unique();
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
  const attempt = await ctx.db.query("teamInviteAttempts").withIndex("by_user", (q) => q.eq("userId", userId)).unique();
  const now = Date.now();
  const current = attempt !== null && now < attempt.windowStart + HOUR;
  if (current && attempt.count >= 30) return { userId, team: null, limited: true };
  const team = await findInvite(ctx, code);
  if (team === null || countAll) {
    if (attempt === null) await ctx.db.insert("teamInviteAttempts", { userId, windowStart: now, count: 1 });
    else await ctx.db.patch("teamInviteAttempts", attempt._id, { windowStart: current ? attempt.windowStart : now, count: current ? attempt.count + 1 : 1 });
  }
  return { userId, team, limited: false };
}

async function uploadClaim(ctx: ReadCtx, file: Id<"_storage">) {
  return await ctx.db.query("teamUploads").withIndex("by_file", (q) => q.eq("file", file)).unique();
}
async function consumeFile(ctx: MutationCtx, file: Id<"_storage">, userId: Id<"users">) {
  const claim = await uploadClaim(ctx, file);
  if (claim === null || claim.userId !== userId || claim.used) fail("INVALID_UPLOAD", "Use a fresh team upload belonging to your account.");
  if (await ctx.db.system.get("_storage", file) === null) fail("FILE_NOT_FOUND", "Upload the team JSON file before saving it.");
  await ctx.db.patch("teamUploads", claim._id, { used: true });
}
// Legacy, unclaimed files may have personal/other-team references. Never delete
// them automatically. All new team files have exclusive ownership enforced above.
async function deleteOwnedFile(ctx: MutationCtx, file: Id<"_storage">) {
  const claim = await uploadClaim(ctx, file);
  if (claim !== null) {
    await ctx.storage.delete(file);
    await ctx.db.delete("teamUploads", claim._id);
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
    await ctx.db.insert("teamUploads", { file, userId, used: false });
    await ctx.scheduler.runAfter(24 * HOUR, internal.teams.expireUpload, { file });
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
    await ctx.runQuery(internal.teams.uploadUser, {});
    const blob = new Blob([json], { type: "application/json" });
    if (blob.size > 2 * 1024 * 1024) fail("INVALID_ARGUMENT", "Team JSON must be at most 2 MiB.");
    try { JSON.parse(json); } catch { fail("INVALID_ARGUMENT", "Upload valid JSON."); }
    const file = await ctx.storage.store(blob);
    try { await ctx.runMutation(internal.teams.registerUpload, { file }); }
    catch (error) { await ctx.storage.delete(file); throw error; }
    return file;
  },
});
// Keeping this internal avoids exposing any new account information.
export const uploadUser = internalQuery({ args: {}, returns: v.id("users"), handler: requireUser });

const cleanupArgs = { teamId: v.id("teams"), userId: v.id("users"), memberId: v.id("teamMembers"), epoch: v.number() };
export async function deleteMemberTrails(ctx: MutationCtx, args: { teamId: Id<"teams">; userId: Id<"users">; memberId: Id<"teamMembers">; epoch: number }) {
  const { teamId, userId, memberId, epoch } = args;
  const tagged = await ctx.db.query("teamTrails").withIndex("by_cleanup", (q) =>
    q.eq("teamId", teamId).eq("userId", userId).eq("memberId", memberId).eq("epoch", epoch)).take(250);
  const legacy = await ctx.db.query("teamTrails").withIndex("by_cleanup", (q) =>
    q.eq("teamId", teamId).eq("userId", userId).eq("memberId", undefined)).take(250);
  for (const trail of [...tagged, ...legacy]) {
    await ctx.db.delete("teamTrails", trail._id);
    await deleteOwnedFile(ctx, trail.file);
  }
  if (tagged.length === 250 || legacy.length === 250) await ctx.scheduler.runAfter(0, internal.teams.cleanupMemberTrails, args);
}
export const cleanupMemberTrails = internalMutation({
  args: cleanupArgs, returns: v.null(),
  handler: async (ctx, args) => { await deleteMemberTrails(ctx, args); return null; },
});
async function removeMembership(ctx: MutationCtx, teamId: Id<"teams">, userId: Id<"users">) {
  const member = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId)).unique();
  if (member === null) return;
  await deleteMemberTrails(ctx, { teamId, userId, memberId: member._id, epoch: member.trailEpoch ?? 0 });
  await ctx.db.delete("teamMembers", member._id);
  if (await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId)).first() !== null) return;
  await ctx.db.delete("teams", teamId);
  await deleteTeamDataBatch(ctx, teamId);
}
async function deleteTeamDataBatch(ctx: MutationCtx, teamId: Id<"teams">) {
  const [places, tiles, trails, secrets, removals] = await Promise.all([
    ctx.db.query("teamPlaces").withIndex("by_team_client", (q) => q.eq("teamId", teamId)).take(500),
    ctx.db.query("teamTiles").withIndex("by_team_received", (q) => q.eq("teamId", teamId)).take(500),
    ctx.db.query("teamTrails").withIndex("by_team_user_walk", (q) => q.eq("teamId", teamId)).take(500),
    ctx.db.query("teamSecrets").withIndex("by_team_secret", (q) => q.eq("teamId", teamId)).take(500),
    ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", teamId)).take(500),
  ]);
  for (const row of [...places, ...trails]) { await ctx.db.delete(row._id); await deleteOwnedFile(ctx, row.file); }
  for (const row of [...tiles, ...secrets, ...removals]) await ctx.db.delete(row._id);
  if ([places, tiles, trails, secrets, removals].some((rows) => rows.length === 500)) await ctx.scheduler.runAfter(0, internal.teams.cleanupEmptyTeam, { teamId });
}
export const cleanupEmptyTeam = internalMutation({
  args: { teamId: v.id("teams") }, returns: v.null(),
  handler: async (ctx, { teamId }) => { if (await ctx.db.get("teams", teamId) === null) await deleteTeamDataBatch(ctx, teamId); return null; },
});

const createArgs = { name: v.string(), colour: v.string(), sharing };
export const createTeam = action({
  args: createArgs, returns: v.object({ teamId: v.id("teams"), inviteCode: v.string() }),
  handler: async (ctx, args): Promise<{ teamId: Id<"teams">; inviteCode: string }> =>
    await ctx.runMutation(internal.teams.createTeamRecord, { ...args, candidates: inviteCandidates() }),
});
export const createTeamRecord = internalMutation({
  args: { ...createArgs, candidates: v.array(v.string()) }, returns: v.object({ teamId: v.id("teams"), inviteCode: v.string() }),
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const name = text(args.name, "Team name"), colour = text(args.colour, "Colour", 64);
    const inviteCode = await availableCode(ctx, args.candidates);
    const now = Date.now();
    const teamId = await ctx.db.insert("teams", { name, createdBy: userId, inviteCode, inviteEpoch: 0, createdAt: now, tilesUpdatedAt: now });
    await ctx.db.insert("teamMembers", { teamId, userId, name: await memberName(ctx, userId), colour, sharing: args.sharing, walksCount: true, joinedAt: now, trailEpoch: 0 });
    return { teamId, inviteCode };
  },
});
export const teamForInvite = mutation({
  args: { code: v.string() }, returns: v.union(v.null(), v.object({ name: v.string(), memberNames: v.array(v.string()) })),
  handler: async (ctx, { code }) => {
    const { userId, team, limited } = await attemptInvite(ctx, code);
    if (limited) fail("RATE_LIMITED", "Try again after the hourly invite limit resets.");
    if (team === null) return null;
    const removed = await ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", team._id).eq("userId", userId)).unique();
    if (removed?.epoch === (team.inviteEpoch ?? 0)) return null;
    // Keep the response shape, but don't disclose people's names before joining.
    return { name: team.name, memberNames: [] };
  },
});
const joinArgs = { code: v.string(), colour: v.string(), sharing, name: v.optional(v.string()) };
export const joinTeam = action({
  args: joinArgs, returns: v.id("teams"),
  handler: async (ctx, args): Promise<Id<"teams">> => {
    const result = await ctx.runMutation(internal.teams.joinTeamRecord, args);
    if (result.error !== undefined) fail(result.error, "This invite is unavailable. Ask the creator for a fresh invite or try again later.");
    return result.teamId!;
  },
});
export const joinTeamRecord = internalMutation({
  args: joinArgs, returns: v.object({ teamId: v.optional(v.id("teams")), error: v.optional(v.string()) }),
  handler: async (ctx, args) => {
    const { userId, team, limited } = await attemptInvite(ctx, args.code, true);
    if (limited) return { error: "RATE_LIMITED" };
    if (team === null) return { error: "INVALID_INVITE" };
    const existing = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", team._id).eq("userId", userId)).unique();
    if (existing !== null) return { teamId: team._id };
    const removed = await ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", team._id).eq("userId", userId)).unique();
    if (removed?.epoch === (team.inviteEpoch ?? 0)) return { error: "MEMBER_REMOVED" };
    const members = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", team._id)).take(MAX_MEMBERS);
    if (members.length >= MAX_MEMBERS) return { error: "TEAM_FULL" };
    await ctx.db.insert("teamMembers", { teamId: team._id, userId, name: await memberName(ctx, userId, args.name), colour: text(args.colour, "Colour", 64), sharing: args.sharing, walksCount: true, joinedAt: Date.now(), trailEpoch: 0 });
    return { teamId: team._id };
  },
});
export const updateMembership = mutation({
  args: { teamId: v.id("teams"), colour: v.optional(v.string()), sharing: v.optional(sharing), walksCount: v.optional(v.boolean()) }, returns: v.null(),
  handler: async (ctx, args) => {
    const { member, userId } = await requireMember(ctx, args.teamId);
    const optOut = args.sharing === "tiles";
    await ctx.db.patch("teamMembers", member._id, {
      ...(args.colour === undefined ? {} : { colour: text(args.colour, "Colour", 64) }),
      ...(args.sharing === undefined ? {} : { sharing: args.sharing }),
      ...(args.walksCount === undefined ? {} : { walksCount: args.walksCount }),
      ...(optOut ? { trailEpoch: (member.trailEpoch ?? 0) + 1 } : {}),
    });
    if (optOut) await deleteMemberTrails(ctx, { teamId: args.teamId, userId, memberId: member._id, epoch: member.trailEpoch ?? 0 });
    return null;
  },
});
export const leaveTeam = mutation({
  args: { teamId: v.id("teams") }, returns: v.null(),
  handler: async (ctx, { teamId }) => { const { userId } = await requireMember(ctx, teamId); await removeMembership(ctx, teamId, userId); return null; },
});
export const renameTeam = mutation({
  args: { teamId: v.id("teams"), name: v.string() }, returns: v.null(),
  handler: async (ctx, { teamId, name }) => { await requireCreator(ctx, teamId); await ctx.db.patch("teams", teamId, { name: text(name, "Team name") }); return null; },
});
export const removeMember = action({
  args: { teamId: v.id("teams"), userId: v.id("users") }, returns: v.null(),
  handler: async (ctx, args): Promise<null> => await ctx.runMutation(internal.teams.removeMemberRecord, { ...args, candidates: inviteCandidates() }),
});
export const removeMemberRecord = internalMutation({
  args: { teamId: v.id("teams"), userId: v.id("users"), candidates: v.array(v.string()) }, returns: v.null(),
  handler: async (ctx, { teamId, userId, candidates }) => {
    const { userId: creator, team } = await requireCreator(ctx, teamId);
    const member = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId)).unique();
    if (member === null) return null;
    if (userId !== creator) {
      const removal = await ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId)).unique();
      if (removal === null) await ctx.db.insert("teamRemovals", { teamId, userId, epoch: team.inviteEpoch ?? 0 });
      else await ctx.db.patch("teamRemovals", removal._id, { epoch: team.inviteEpoch ?? 0 });
      await ctx.db.patch("teams", teamId, { inviteCode: await availableCode(ctx, candidates) });
    }
    await removeMembership(ctx, teamId, userId);
    return null;
  },
});
export const newInviteCode = action({
  args: { teamId: v.id("teams") }, returns: v.string(),
  handler: async (ctx, args): Promise<string> => await ctx.runMutation(internal.teams.rotateInvite, { ...args, candidates: inviteCandidates() }),
});
export const rotateInvite = internalMutation({
  args: { teamId: v.id("teams"), candidates: v.array(v.string()) }, returns: v.string(),
  handler: async (ctx, { teamId, candidates }) => {
    const { team } = await requireCreator(ctx, teamId);
    const inviteCode = await availableCode(ctx, candidates);
    await ctx.db.patch("teams", teamId, { inviteCode, inviteEpoch: (team.inviteEpoch ?? 0) + 1 });
    return inviteCode;
  },
});

const placeArgs = { teamId: v.id("teams"), clientId: v.string(), name: v.string(), file: v.id("_storage"), bounds: boundsValidator, gridPlaceId: v.optional(v.union(v.id("teamPlaces"), v.null())) };
export const addTeamPlace = action({
  args: placeArgs, returns: v.id("teamPlaces"),
  handler: async (ctx, args): Promise<Id<"teamPlaces">> => {
    try { return await ctx.runMutation(internal.teams.addPlaceRecord, args); }
    catch (error) { await ctx.runMutation(internal.teams.discardUpload, { file: args.file }); throw error; }
  },
});
export const addPlaceRecord = internalMutation({
  args: placeArgs, returns: v.id("teamPlaces"),
  handler: async (ctx, args) => {
    const { userId } = await requireMember(ctx, args.teamId);
    const clientId = text(args.clientId, "Place id", 200);
    const existing = await ctx.db.query("teamPlaces").withIndex("by_team_client", (q) => q.eq("teamId", args.teamId).eq("clientId", clientId)).unique();
    if (existing !== null) { if (existing.file !== args.file) await discardFile(ctx, args.file, userId); return existing._id; }
    const { minQ, maxQ, minR, maxR } = args.bounds;
    if (!Object.values(args.bounds).every((n) => Number.isSafeInteger(n) && Math.abs(n) <= 1_000_000) || minQ > maxQ || minR > maxR || maxQ - minQ > 10_000 || maxR - minR > 10_000) fail("INVALID_ARGUMENT", "Supply a valid, bounded axial grid extent.");
    const places = await ctx.db.query("teamPlaces").withIndex("by_team_client", (q) => q.eq("teamId", args.teamId)).take(MAX_PLACES);
    if (places.length >= MAX_PLACES) fail("PLACE_LIMIT", "A team can contain at most 16 places.");
    // A first-place upload must still be first when it commits. Later places
    // reference a grid they actually downloaded. No schema or file parsing needed.
    if (args.gridPlaceId !== undefined && (args.gridPlaceId === null ? places.length > 0 : !places.some((p) => p._id === args.gridPlaceId))) {
      fail("GRID_CHANGED", "Refresh the team and rebuild this place on its shared grid.");
    }
    await consumeFile(ctx, args.file, userId);
    return await ctx.db.insert("teamPlaces", { teamId: args.teamId, file: args.file, bounds: args.bounds, clientId, name: text(args.name, "Place name"), addedBy: userId, updatedAt: Date.now(), tileCount: 0 });
  },
});
export const uploadTeamTiles = mutation({
  args: { teamId: v.id("teams"), placeId: v.id("teamPlaces"), hexes: v.array(v.array(v.number())), at: v.number(), discoveredAt: v.optional(v.array(v.number())) }, returns: v.number(),
  handler: async (ctx, { teamId, placeId, hexes, at, discoveredAt }) => {
    const { userId, team, member } = await requireMember(ctx, teamId);
    if (!member.walksCount) fail("CONTRIBUTIONS_PAUSED", "Resume contributions before sharing discoveries.");
    const place = await ctx.db.get("teamPlaces", placeId);
    if (place === null || place.teamId !== teamId) fail("PLACE_NOT_FOUND", "This place is not part of this team map.");
    finite(at, "Discovery time");
    if (discoveredAt !== undefined && (discoveredAt.length !== hexes.length || discoveredAt.some((time) => !Number.isFinite(time)))) fail("INVALID_ARGUMENT", "Supply one finite discovery time per tile.");
    if (hexes.length > 1000 || hexes.some((h) => h.length !== 2 || !h.every(Number.isSafeInteger))) fail("INVALID_ARGUMENT", "Send at most 1,000 integer [q, r] pairs.");
    if (place.bounds === undefined || place.tileCount === undefined) fail("PLACE_BOUNDS_REQUIRED", "This legacy place needs verified grid bounds before accepting more tiles.");
    const { minQ, maxQ, minR, maxR } = place.bounds;
    if (hexes.some(([q, r]) => q < minQ || q > maxQ || r < minR || r > maxR)) fail("INVALID_ARGUMENT", "Tile coordinates must be inside the place's grid extent.");
    const receivedAt = Math.max(Date.now(), team.tilesUpdatedAt + 1);
    let added = 0;
    for (const [index, [rawQ, rawR]] of hexes.entries()) {
      const q = rawQ === 0 ? 0 : rawQ, r = rawR === 0 ? 0 : rawR;
      const existing = await ctx.db.query("teamTiles").withIndex("by_team_place_hex", (index) => index.eq("teamId", teamId).eq("placeId", placeId).eq("q", q).eq("r", r)).unique();
      if (existing !== null) continue;
      if (place.tileCount + added >= MAX_TILES) fail("TILE_LIMIT", "This place has reached its 50,000 tile limit.");
      await ctx.db.insert("teamTiles", { teamId, placeId, q, r, by: userId, at: discoveredAt?.[index] ?? at, receivedAt });
      added++;
    }
    if (added > 0) {
      await ctx.db.patch("teams", teamId, { tilesUpdatedAt: receivedAt });
      await ctx.db.patch("teamPlaces", placeId, { tileCount: place.tileCount + added });
    }
    return added;
  },
});
const trailArgs = { teamId: v.id("teams"), walkClientId: v.string(), file: v.id("_storage"), updatedAt: v.number() };
export const uploadTeamTrail = action({
  args: trailArgs, returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    try { return await ctx.runMutation(internal.teams.uploadTrailRecord, args); }
    catch (error) { await ctx.runMutation(internal.teams.discardUpload, { file: args.file }); throw error; }
  },
});
export const uploadTrailRecord = internalMutation({
  args: trailArgs, returns: v.null(),
  handler: async (ctx, args) => {
    const { userId, member } = await requireMember(ctx, args.teamId);
    if (!member.walksCount) fail("CONTRIBUTIONS_PAUSED", "Resume contributions before sharing a route.");
    if (member.sharing !== "tilesAndTrail") fail("TRAIL_SHARING_DISABLED", "Enable tiles and trail sharing before uploading a route.");
    const walkClientId = text(args.walkClientId, "Walk id", 200);
    finite(args.updatedAt, "Route version");
    const existing = await ctx.db.query("teamTrails").withIndex("by_team_user_walk", (q) => q.eq("teamId", args.teamId).eq("userId", userId).eq("walkClientId", walkClientId)).unique();
    if (existing?.file === args.file) return null;
    if (existing !== null && args.updatedAt <= (existing.updatedAt ?? 0)) { await discardFile(ctx, args.file, userId); return null; }
    const trails = await ctx.db.query("teamTrails").withIndex("by_team_user_walk", (q) => q.eq("teamId", args.teamId).eq("userId", userId)).take(MAX_TRAILS);
    if (existing === null && trails.length >= MAX_TRAILS) fail("TRAIL_LIMIT", "A member can share at most 64 trails per team.");
    await consumeFile(ctx, args.file, userId);
    const fields = { file: args.file, at: Date.now(), updatedAt: args.updatedAt, memberId: member._id, epoch: member.trailEpoch ?? 0 };
    if (existing === null) await ctx.db.insert("teamTrails", { teamId: args.teamId, userId, walkClientId, ...fields });
    else { await ctx.db.patch("teamTrails", existing._id, fields); await deleteOwnedFile(ctx, existing.file); }
    return null;
  },
});
export const recordTeamSecrets = mutation({
  args: { teamId: v.id("teams"), secrets: v.array(v.object({ secretId: v.string(), at: v.number() })) }, returns: v.null(),
  handler: async (ctx, { teamId, secrets }) => {
    const { userId, member } = await requireMember(ctx, teamId);
    if (!member.walksCount) fail("CONTRIBUTIONS_PAUSED", "Resume contributions before sharing discoveries.");
    if (secrets.length > 1000) fail("INVALID_ARGUMENT", "Send at most 1,000 secrets per call.");
    let count = (await ctx.db.query("teamSecrets").withIndex("by_team_secret", (q) => q.eq("teamId", teamId)).take(MAX_SECRETS)).length;
    for (const secret of secrets) {
      const secretId = text(secret.secretId, "Secret id", 200); finite(secret.at, "Discovery time");
      const existing = await ctx.db.query("teamSecrets").withIndex("by_team_secret", (q) => q.eq("teamId", teamId).eq("secretId", secretId)).unique();
      if (existing === null) {
        if (count >= MAX_SECRETS) fail("SECRET_LIMIT", "A team can contain at most 1,000 secrets.");
        await ctx.db.insert("teamSecrets", { teamId, secretId, by: userId, at: secret.at }); count++;
      }
    }
    return null;
  },
});
export const teamSnapshot = query({
  args: { teamId: v.id("teams"), since: v.optional(v.number()), cursor: v.optional(tileCursor) },
  returns: v.object({
    team: teamInfo, members: v.array(memberInfo), serverTime: v.number(), cursor: v.union(tileCursor, v.null()), more: v.boolean(),
    places: v.array(v.object({ placeId: v.id("teamPlaces"), clientId: v.string(), name: v.string(), updatedAt: v.number(), url: nullableUrl })),
    tiles: v.array(v.object({ placeId: v.id("teamPlaces"), q: v.number(), r: v.number(), by: v.id("users"), at: v.number() })),
    trails: v.array(v.object({ walkClientId: v.string(), url: nullableUrl, by: v.id("users"), at: v.number() })),
    secrets: v.array(v.object({ secretId: v.string(), by: v.id("users"), at: v.number() })),
  }),
  handler: async (ctx, { teamId, since, cursor }) => {
    const { userId, team } = await requireMember(ctx, teamId);
    if (since !== undefined) finite(since, "Snapshot cursor");
    if (cursor !== undefined && (cursor.since !== (since ?? null) || !Number.isFinite(cursor.until))) fail("INVALID_ARGUMENT", "Keep since unchanged while paging a snapshot.");
    const until = cursor?.until ?? Math.max(team.tilesUpdatedAt, since ?? 0);
    const [members, places, tilePage, trails, secrets] = await Promise.all([
      ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId)).take(MAX_MEMBERS),
      ctx.db.query("teamPlaces").withIndex("by_team_client", (q) => q.eq("teamId", teamId)).take(MAX_PLACES),
      ctx.db.query("teamTiles").withIndex("by_team_received", (q) => since === undefined ? q.eq("teamId", teamId).lte("receivedAt", until) : q.eq("teamId", teamId).gt("receivedAt", since).lte("receivedAt", until)).paginate({ cursor: cursor?.position ?? null, numItems: 1000 }),
      ctx.db.query("teamTrails").withIndex("by_team_user_walk", (q) => q.eq("teamId", teamId)).take(MAX_MEMBERS * MAX_TRAILS),
      ctx.db.query("teamSecrets").withIndex("by_team_secret", (q) => q.eq("teamId", teamId)).take(MAX_SECRETS),
    ]);
    const sharingMembers = new Map(members.filter((m) => m.sharing === "tilesAndTrail").map((m) => [m.userId, m]));
    return {
      team: { teamId, name: team.name, createdBy: team.createdBy, inviteCode: team.inviteCode, createdAt: team.createdAt },
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
export const myTeams = query({
  args: {}, returns: v.array(v.object({ teamId: v.id("teams"), name: v.string(), memberCount: v.number(), membership: memberInfo })),
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const memberships = await ctx.db.query("teamMembers").withIndex("by_user", (q) => q.eq("userId", userId)).collect();
    return await Promise.all(memberships.map(async (m) => {
      const team = await ctx.db.get("teams", m.teamId);
      if (team === null) fail("TEAM_NOT_FOUND", "This team map no longer exists.");
      const members = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", m.teamId)).take(MAX_MEMBERS);
      return { teamId: team._id, name: team.name, memberCount: members.length, membership: { userId, name: m.name, colour: m.colour, sharing: m.sharing, walksCount: m.walksCount, joinedAt: m.joinedAt, isYou: true } };
    }));
  },
});

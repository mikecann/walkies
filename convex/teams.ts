import { ConvexError, v } from "convex/values";
import { action, internalMutation, mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { currentUserId } from "./users";

const nullableUrl = v.union(v.string(), v.null());
const inviteAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const memberInfo = v.object({
  userId: v.id("users"), name: v.string(), colour: v.string(),
  joinedAt: v.number(), isYou: v.boolean(),
  // The member's Google photo, for their head in the app. Only fellow members see it.
  picture: nullableUrl,
});
const MAX_MEMBERS = 8;
const HOUR = 60 * 60 * 1000;
type ReadCtx = QueryCtx | MutationCtx;
function fail(code: string, message: string): never { throw new ConvexError({ code, message }); }
function text(value: string, label: string, max = 100) {
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > max) fail("INVALID_ARGUMENT", `${label} must contain 1–${max} characters.`);
  return trimmed;
}
async function requireUser(ctx: ReadCtx) {
  const userId = await currentUserId(ctx);
  if (userId === null || await ctx.db.get("users", userId) === null) fail("UNAUTHENTICATED", "Sign in to use teams.");
  return userId;
}
async function requireMember(ctx: ReadCtx, teamId: Id<"teams">) {
  const userId = await requireUser(ctx);
  const member = await ctx.db.query("teamMembers")
    .withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId)).unique();
  if (member === null) fail("NOT_A_MEMBER", "You are not a member of this team.");
  const team = await ctx.db.get("teams", teamId);
  if (team === null) fail("TEAM_NOT_FOUND", "This team no longer exists.");
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
async function memberPicture(ctx: ReadCtx, userId: Id<"users">) {
  return (await ctx.db.get("users", userId))?.picture ?? null;
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

async function removeMembership(ctx: MutationCtx, teamId: Id<"teams">, userId: Id<"users">) {
  const member = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId)).unique();
  if (member === null) return;
  await ctx.db.delete("teamMembers", member._id);
  if (await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId)).first() !== null) return;
  await ctx.db.delete("teams", teamId);
  await deleteTeamDataBatch(ctx, teamId);
}
async function deleteTeamDataBatch(ctx: MutationCtx, teamId: Id<"teams">) {
  const removals = await ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", teamId)).take(500);
  for (const row of removals) await ctx.db.delete("teamRemovals", row._id);
  if (removals.length === 500) await ctx.scheduler.runAfter(0, internal.teams.cleanupEmptyTeam, { teamId });
}
export const cleanupEmptyTeam = internalMutation({
  args: { teamId: v.id("teams") }, returns: v.null(),
  handler: async (ctx, { teamId }) => { if (await ctx.db.get("teams", teamId) === null) await deleteTeamDataBatch(ctx, teamId); return null; },
});

const createArgs = { name: v.string(), colour: v.string(), memberName: v.optional(v.string()) };
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
    const teamId = await ctx.db.insert("teams", { name, createdBy: userId, inviteCode, inviteEpoch: 0, createdAt: now });
    await ctx.db.insert("teamMembers", { teamId, userId, name: await memberName(ctx, userId, args.memberName), colour, joinedAt: now });
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
const joinArgs = { code: v.string(), colour: v.string(), name: v.optional(v.string()) };
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
    await ctx.db.insert("teamMembers", { teamId: team._id, userId, name: await memberName(ctx, userId, args.name), colour: text(args.colour, "Colour", 64), joinedAt: Date.now() });
    return { teamId: team._id };
  },
});
export const updateMembership = mutation({
  args: { teamId: v.id("teams"), colour: v.optional(v.string()), name: v.optional(v.string()) }, returns: v.null(),
  handler: async (ctx, args) => {
    const { member } = await requireMember(ctx, args.teamId);
    await ctx.db.patch("teamMembers", member._id, {
      ...(args.colour === undefined ? {} : { colour: text(args.colour, "Colour", 64) }),
      ...(args.name === undefined ? {} : { name: text(args.name, "Your name") }),
    });
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

/** Membership is the only team state. Photos are visible only to fellow members. */
export const myTeams = query({
  args: {}, returns: v.array(v.object({
    teamId: v.id("teams"), name: v.string(), createdBy: v.id("users"),
    inviteCode: v.string(), createdAt: v.number(), members: v.array(memberInfo),
  })),
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const memberships = await ctx.db.query("teamMembers").withIndex("by_user", (q) => q.eq("userId", userId)).collect();
    return await Promise.all(memberships.map(async (membership) => {
      const team = await ctx.db.get("teams", membership.teamId);
      if (team === null) fail("TEAM_NOT_FOUND", "This team no longer exists.");
      const members = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", team._id)).take(MAX_MEMBERS);
      return {
        teamId: team._id, name: team.name, createdBy: team.createdBy, inviteCode: team.inviteCode, createdAt: team.createdAt,
        members: await Promise.all(members.map(async (member) => ({
          userId: member.userId, name: member.name, colour: member.colour, joinedAt: member.joinedAt,
          isYou: member.userId === userId, picture: await memberPicture(ctx, member.userId),
        }))),
      };
    }));
  },
});

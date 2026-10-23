import { v } from "convex/values";
import { components, internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";

// Deleting an account (users:deleteAccount, App Store Guideline 5.1.1(v)). The person
// is signed out at once: their user row loses its name, email and photo and becomes a
// tombstone every session treats as signed out (currentUserId in users.ts). Their rows
// go here, in the background, a batch per step, each step scheduling the next. Progress
// lives in `accountDeletions`, so an interrupted run picks up where it left off
// (`resumeStalled`, hourly from crons.ts), and running a step twice only finds less to
// delete. Shared OSM street data (placeData) isn't anyone's, so it stays.

/** Rows deleted per step. Walks and places each take a storage file with them. */
export const BATCH = 200;
/** Steps that haven't run for this long are restarted by the cron. */
export const STALL_MS = 10 * 60_000;
/** Extra passes allowed when rows turn up behind the sweep (a sync that was mid-flight). */
const MAX_PASSES = 5;

type UserId = Id<"users">;
/** Deletes up to `budget` of the person's rows in one stage. Returns how many it deleted. */
type Sweep = (ctx: MutationCtx, userId: UserId, budget: number) => Promise<number>;

/**
 * Every table with a `userId`, by an index that starts with it. Keep this in step with
 * schema.ts: accountDeletion.test.ts checks that every table with a `userId` is here.
 */
export const PERSONAL_INDEX = {
  teamMembers: "by_user",
  walks: "by_user_client",
  places: "by_user_client",
  progress: "by_user",
  secrets: "by_user_secret",
  teamRemovals: "by_user",
  teamInviteAttempts: "by_user",
  placeCalls: "by_user",
} as const;
type PersonalTable = keyof typeof PERSONAL_INDEX;

/** The first `n` of someone's rows in a personal table. */
async function firstRows(ctx: QueryCtx, table: PersonalTable, userId: UserId, n: number): Promise<Doc<PersonalTable>[]> {
  // The index name and its leading `userId` field come from PERSONAL_INDEX, which
  // Convex's types can't check through a table-name variable.
  const query = ctx.db.query(table) as unknown as {
    withIndex(index: string, range: (q: { eq(field: "userId", value: UserId): unknown }) => unknown): {
      take(n: number): Promise<Doc<PersonalTable>[]>;
    };
  };
  return await query.withIndex(PERSONAL_INDEX[table], (q) => q.eq("userId", userId)).take(n);
}

const plain = (table: PersonalTable): Sweep => async (ctx, userId, budget) => {
  const rows = await firstRows(ctx, table, userId, budget);
  for (const row of rows) await ctx.db.delete(row._id);
  return rows.length;
};

/** Walks and places keep their contents in file storage, which goes too. */
const withFiles = (table: "walks" | "places"): Sweep => async (ctx, userId, budget) => {
  const rows = await ctx.db.query(table).withIndex("by_user_client", (q) => q.eq("userId", userId)).take(budget);
  for (const row of rows) {
    await ctx.db.delete(row._id);
    // Already gone is fine: a step that ran twice, or a file that never finished uploading.
    await ctx.storage.delete(row.file).catch(() => {});
  }
  return rows.length;
};

/**
 * The stages, in order. Teams go first: they leave each team, and a team they made
 * that still has people in it is handed to whoever's been in it longest, so nobody
 * else loses their team. Chef's rows live in its component.
 */
const SWEEPS: Record<PersonalTable | "chefRequests", Sweep> = {
  teamMembers: async (ctx, userId, budget) => {
    const rows = await ctx.db.query("teamMembers").withIndex("by_user", (q) => q.eq("userId", userId)).take(budget);
    for (const row of rows) {
      await ctx.db.delete(row._id);
      const team = await ctx.db.get(row.teamId);
      if (team === null) continue;
      const rest = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", team._id)).collect();
      if (rest.length === 0) {
        // Nobody left: the team goes, with its removal records (teams.ts does the same).
        await ctx.db.delete(team._id);
        for (const removal of await ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", team._id)).collect()) {
          await ctx.db.delete(removal._id);
        }
      } else if (team.createdBy === userId) {
        const next = rest.sort((a, b) => a.joinedAt - b.joinedAt)[0]!;
        await ctx.db.patch(team._id, { createdBy: next.userId });
      }
    }
    // A team they made but had already left still names them as its creator.
    for (const team of await ctx.db.query("teams").withIndex("by_creator", (q) => q.eq("createdBy", userId)).take(budget)) {
      const next = (await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", team._id)).collect())
        .sort((a, b) => a.joinedAt - b.joinedAt)[0];
      if (next) await ctx.db.patch(team._id, { createdBy: next.userId });
      else await ctx.db.delete(team._id);
    }
    return rows.length;
  },
  walks: withFiles("walks"),
  places: withFiles("places"),
  progress: plain("progress"),
  secrets: plain("secrets"),
  teamRemovals: plain("teamRemovals"),
  teamInviteAttempts: plain("teamInviteAttempts"),
  placeCalls: plain("placeCalls"),
  // Chef: their feature requests, with screenshots, voice notes, votes on them and
  // notifications (the feedback component's items.remove). Counts requests, not rows.
  chefRequests: async (ctx, userId, budget) => {
    let deleted = 0;
    while (deleted < budget) {
      const items = await ctx.runQuery(components.feedback.items.listByCreator, { userId, limit: Math.min(20, budget - deleted) });
      if (items.length === 0) break;
      for (const item of items) await ctx.runMutation(components.feedback.items.remove, { itemId: item._id });
      deleted += items.length;
    }
    return deleted;
  },
};

/** The order the stages run in. */
export const STAGES = Object.keys(SWEEPS) as (keyof typeof SWEEPS)[];

/** Starts (or restarts) deleting someone's data. An unfinished deletion is picked up, not started twice. */
export async function startDeletion(ctx: MutationCtx, userId: UserId): Promise<Id<"accountDeletions">> {
  const now = Date.now();
  const existing = await ctx.db
    .query("accountDeletions")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .order("desc")
    .first();
  if (existing && existing.finishedAt === undefined) {
    await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId: existing._id });
    return existing._id;
  }
  const deletionId = await ctx.db.insert("accountDeletions", {
    userId, requestedAt: now, stage: STAGES[0]!, passes: 0, deletedRows: 0, lastStepAt: now,
  });
  await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId });
  return deletionId;
}

/** Whether anything of theirs is left, in any stage. */
async function anythingLeft(ctx: MutationCtx, userId: UserId): Promise<boolean> {
  for (const table of Object.keys(PERSONAL_INDEX) as PersonalTable[]) {
    if ((await firstRows(ctx, table, userId, 1)).length > 0) return true;
  }
  if (await ctx.db.query("teams").withIndex("by_creator", (q) => q.eq("createdBy", userId)).first()) return true;
  return (await ctx.runQuery(components.feedback.items.listByCreator, { userId, limit: 1 })).length > 0;
}

/** One step: up to BATCH rows, across as many stages as that reaches, then the next step. */
export const step = internalMutation({
  args: { deletionId: v.id("accountDeletions") },
  returns: v.null(),
  handler: async (ctx, { deletionId }) => {
    const deletion = await ctx.db.get(deletionId);
    if (!deletion || deletion.finishedAt !== undefined) return null;
    const { userId } = deletion;
    let stageIndex = Math.max(0, STAGES.indexOf(deletion.stage as (typeof STAGES)[number]));
    let budget = BATCH;
    let deleted = 0;
    while (budget > 0 && stageIndex < STAGES.length) {
      const n = await SWEEPS[STAGES[stageIndex]!](ctx, userId, budget);
      deleted += n;
      budget -= n;
      // Fewer than asked for: this stage is empty.
      if (budget > 0) stageIndex++;
    }
    const now = Date.now();
    const progress = { deletedRows: deletion.deletedRows + deleted, lastStepAt: now };
    if (stageIndex < STAGES.length) {
      await ctx.db.patch(deletionId, { ...progress, stage: STAGES[stageIndex]! });
      await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId });
      return null;
    }
    // Every stage came up empty. Something written behind the sweep gets another pass.
    if (deletion.passes + 1 < MAX_PASSES && (await anythingLeft(ctx, userId))) {
      await ctx.db.patch(deletionId, { ...progress, stage: STAGES[0]!, passes: deletion.passes + 1 });
      await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId });
      return null;
    }
    await ctx.db.patch(deletionId, { ...progress, stage: "done", passes: deletion.passes + 1, finishedAt: now });
    console.log(`Account deletion ${deletionId} finished: ${progress.deletedRows} rows`);
    return null;
  },
});

/** Cron, hourly: restarts deletions whose chain of steps stopped (a deploy, an error). */
export const resumeStalled = internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const stalled = await ctx.db
      .query("accountDeletions")
      .withIndex("by_finishedAt_lastStepAt", (q) => q.eq("finishedAt", undefined).lt("lastStepAt", Date.now() - STALL_MS))
      .take(50);
    for (const d of stalled) {
      await ctx.db.patch(d._id, { lastStepAt: Date.now() });
      await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId: d._id });
    }
    return stalled.length;
  },
});

/** Whether this person's data is still being deleted (they can't sign back in until it's done). */
export async function deletionInProgress(ctx: QueryCtx, userId: UserId): Promise<boolean> {
  const latest = await ctx.db
    .query("accountDeletions")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .order("desc")
    .first();
  return latest !== null && latest.finishedAt === undefined;
}

/**
 * How many rows someone has left in each personal table (capped at 1000 each), plus
 * their Chef requests and latest deletion, for checking a deletion by hand:
 * `npx convex run accountDeletion:remaining '{"userId":"…"}' --prod`.
 */
export const remaining = internalQuery({
  args: { userId: v.id("users") },
  returns: v.object({
    counts: v.record(v.string(), v.number()),
    deletion: v.union(v.null(), v.object({ stage: v.string(), deletedRows: v.number(), finished: v.boolean() })),
  }),
  handler: async (ctx, { userId }) => {
    const counts: Record<string, number> = {};
    for (const table of Object.keys(PERSONAL_INDEX) as PersonalTable[]) {
      counts[table] = (await firstRows(ctx, table, userId, 1000)).length;
    }
    counts.teamsCreated = (await ctx.db.query("teams").withIndex("by_creator", (q) => q.eq("createdBy", userId)).take(1000)).length;
    counts.chefRequests = (await ctx.runQuery(components.feedback.items.listByCreator, { userId, limit: 100 })).length;
    const latest = await ctx.db
      .query("accountDeletions")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .order("desc")
      .first();
    return {
      counts,
      deletion: latest && { stage: latest.stage, deletedRows: latest.deletedRows, finished: latest.finishedAt !== undefined },
    };
  },
});

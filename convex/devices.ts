import { ConvexError, v } from "convex/values";
import { components, internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, mutation, type MutationCtx, type QueryCtx } from "./_generated/server";
import { currentUserId } from "./users";

// Phones and their push tokens, and who each push goes to. apns.ts sends them.

/**
 * Just what working out a push needs: reads, the component's admin list and the scheduler. Narrow,
 * so the state machines' own ctx (which refuses writes to their tables) fits too.
 */
type PushCtx = Pick<QueryCtx, "runQuery"> & {
  db: Pick<QueryCtx["db"], "query" | "get" | "normalizeId">;
  scheduler: MutationCtx["scheduler"];
};

const vEnvironment = v.union(v.literal("sandbox"), v.literal("production"));

/** The app calls this whenever iOS hands it a push token, and after signing in. */
export const register = mutation({
  args: {
    deviceId: v.string(),
    platform: v.string(),
    apnsToken: v.optional(v.string()),
    apnsEnvironment: v.optional(vEnvironment),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const userId = await currentUserId(ctx);
    if (userId === null) throw new ConvexError("Not signed in");
    const now = Date.now();
    // A token belongs to one phone; take it off any other row, whoever's it is.
    if (args.apnsToken) {
      for (const h of await ctx.db.query("devices").withIndex("by_apnsToken", (q) => q.eq("apnsToken", args.apnsToken)).collect()) {
        if (h.deviceId !== args.deviceId) await ctx.db.patch("devices", h._id, { apnsToken: undefined, updatedAt: now });
      }
    }
    const rows = await ctx.db.query("devices").withIndex("by_deviceId", (q) => q.eq("deviceId", args.deviceId)).collect();
    const mine = rows.find((d) => d.userId === userId);
    // Someone else signed in on this phone before: their pushes stop coming here.
    for (const d of rows) if (d !== mine && d.apnsToken) await ctx.db.patch("devices", d._id, { apnsToken: undefined, updatedAt: now });
    if (mine) await ctx.db.patch("devices", mine._id, { ...args, updatedAt: now });
    else await ctx.db.insert("devices", { ...args, userId, updatedAt: now });
    return null;
  },
});

/** Signing out: this phone stops getting that account's pushes. */
export const unregister = mutation({
  args: { deviceId: v.string() },
  returns: v.null(),
  handler: async (ctx, { deviceId }) => {
    const userId = await currentUserId(ctx);
    if (userId === null) return null;
    for (const d of await ctx.db.query("devices").withIndex("by_deviceId", (q) => q.eq("deviceId", deviceId)).collect()) {
      if (d.userId === userId) await ctx.db.delete("devices", d._id);
    }
    return null;
  },
});

const vTarget = v.object({ token: v.string(), environment: v.optional(vEnvironment) });

/** Every push token of these people. */
export const pushTargets = internalQuery({
  args: { userIds: v.array(v.id("users")) },
  returns: v.array(vTarget),
  handler: async (ctx, { userIds }) => {
    const targets = [];
    for (const userId of new Set(userIds)) {
      for (const d of await ctx.db.query("devices").withIndex("by_user", (q) => q.eq("userId", userId)).collect()) {
        if (d.apnsToken) targets.push({ token: d.apnsToken, environment: d.apnsEnvironment });
      }
    }
    return targets;
  },
});

/** APNs said the token's dead. */
export const dropToken = internalMutation({
  args: { token: v.string() },
  returns: v.null(),
  handler: async (ctx, { token }) => {
    for (const h of await ctx.db.query("devices").withIndex("by_apnsToken", (q) => q.eq("apnsToken", token)).collect()) {
      await ctx.db.patch("devices", h._id, { apnsToken: undefined, updatedAt: Date.now() });
    }
    return null;
  },
});

/** Apple took the token in the other environment than the app said (apns.ts). */
export const setTokenEnvironment = internalMutation({
  args: { token: v.string(), environment: vEnvironment },
  returns: v.null(),
  handler: async (ctx, { token, environment }) => {
    for (const h of await ctx.db.query("devices").withIndex("by_apnsToken", (q) => q.eq("apnsToken", token)).collect()) {
      await ctx.db.patch("devices", h._id, { apnsEnvironment: environment, updatedAt: Date.now() });
    }
    return null;
  },
});

/** Chef's admins (Mike) who are real accounts here, not the CLI's `operator:` identity. */
export async function admins(ctx: Pick<PushCtx, "runQuery" | "db">): Promise<Id<"users">[]> {
  const ids: string[] = await ctx.runQuery(components.feedback.users.listAdmins, {});
  return ids.flatMap((id) => {
    const userId = ctx.db.normalizeId("users", id);
    return userId ? [userId] : [];
  });
}

const vPush = v.object({ userIds: v.array(v.id("users")), title: v.string(), body: v.string(), threadId: v.string() });

/** Sends each of these pushes after the mutation commits, so a push can never hold it up or undo it. */
export async function sendPushes(ctx: PushCtx, pushes: { userIds: Id<"users">[]; title: string; body: string; threadId: string }[]) {
  for (const push of pushes) if (push.userIds.length > 0) await ctx.scheduler.runAfter(0, internal.apns.send, push);
}

/** A push is a nicety: working out who gets one must never fail the sync or publish it rides on. */
async function quietly(what: string, work: () => Promise<void>) {
  try {
    await work();
  } catch (error) {
    console.error(`[push] couldn't work out the ${what} push: ${error instanceof Error ? error.message : String(error)}`);
  }
}
export { vPush };

/**
 * A suburb's research has finished. The people who have it as a place hear when there are
 * secrets to find; the admin hears how it went either way, with how many wait for their OK.
 */
export async function loreFinished(
  ctx: PushCtx,
  { osmId, name, outcome, live, pending, error }: {
    osmId: number; name: string; outcome: "ready" | "quiet" | "failed"; live: number; pending: number; error?: string;
  },
) {
  await quietly("secrets", async () => {
    const adminIds = await admins(ctx);
    const pushes = [];
    if (live > 0) {
      const owners = (await ctx.db.query("places").withIndex("by_osm", (q) => q.eq("osmId", osmId)).collect()).map((p) => p.userId);
      // The admin gets their own, fuller one below.
      const userIds = [...new Set(owners)].filter((id) => !adminIds.includes(id));
      pushes.push({
        userIds, title: `New secrets in ${name}`,
        body: `${live} ${live === 1 ? "secret is" : "secrets are"} hidden in ${name}. Go for a walk to find them.`,
        threadId: `lore-${osmId}`,
      });
    }
    const waiting = pending > 0 ? `, ${pending} waiting for your OK` : "";
    const body = outcome === "failed" ? `Research failed: ${error ?? "no reason given"}`
      : outcome === "quiet" ? `Quiet: ${live} live${waiting}.`
      : `${live} live${waiting}.`;
    pushes.push({ userIds: adminIds, title: `Secrets for ${name}`, body, threadId: "admin-lore" });
    await sendPushes(ctx, pushes);
  });
}

/** Someone added a place to their account. The admin hears about everyone's but their own. */
export async function placeAdded(ctx: PushCtx, userId: Id<"users">, placeName: string) {
  await quietly("new place", async () => {
    const adminIds = (await admins(ctx)).filter((id) => id !== userId);
    if (adminIds.length === 0) return;
    const who = (await ctx.db.get("users", userId))?.name?.trim() || "Someone";
    await sendPushes(ctx, [{ userIds: adminIds, title: "New place", body: `${who} added ${placeName}`, threadId: "admin-places" }]);
  });
}

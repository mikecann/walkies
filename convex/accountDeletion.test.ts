/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import feedbackTest from "@convex-dev/feedback/test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { api, components, internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { BATCH, PERSONAL_INDEX, STALL_MS } from "./accountDeletion";
import schema from "./schema";

// users:deleteAccount and the background deletion (accountDeletion.ts).

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);
const TABLES = Object.keys(PERSONAL_INDEX) as (keyof typeof PERSONAL_INDEX)[];
type T = ReturnType<typeof convexTest>;

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

async function setup() {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  feedbackTest.register(t);
  const [aliceId, bobId] = await t.run(async (ctx) => Promise.all([
    ctx.db.insert("users", { name: "Alice", email: "alice@example.com", emailVerified: true, picture: "https://example.com/a.png" }),
    ctx.db.insert("users", { name: "Bob", email: "bob@example.com", emailVerified: true }),
  ]));
  const alice = t.withIdentity({ subject: aliceId });
  const bob = t.withIdentity({ subject: bobId });
  return { t, alice, bob, aliceId, bobId };
}

const drain = (t: T) => t.finishAllScheduledFunctions(() => vi.runAllTimers());

/** `n` walks and places with files, progress, secrets, rate-limit rows and a Chef request. */
async function seed(t: T, userId: Id<"users">, n = 2) {
  return await t.run(async (ctx) => {
    const files: Id<"_storage">[] = [];
    for (let i = 0; i < n; i++) {
      const walkFile = await ctx.storage.store(new Blob([`walk ${i}`]));
      const placeFile = await ctx.storage.store(new Blob([`place ${i}`]));
      files.push(walkFile, placeFile);
      await ctx.db.insert("walks", { userId, clientId: `w${i}`, startedAt: i, endedAt: i + 1, distance: 1000, newTiles: 3, file: walkFile });
      await ctx.db.insert("places", { userId, clientId: `p${i}`, name: "Fremantle", createdAt: i, updatedAt: i, file: placeFile });
      await ctx.db.insert("secrets", { userId, secretId: `s${i}`, foundAt: i });
    }
    await ctx.db.insert("progress", { userId, ledger: "{}", updatedAt: 0 });
    await ctx.db.insert("teamInviteAttempts", { userId, windowStart: 0, count: 1 });
    await ctx.db.insert("placeCalls", { userId, windowStart: 0, count: 1 });
    await ctx.db.insert("loreCalls", { userId, windowStart: 0, count: 1 });
    await ctx.db.insert("loreRequests", { userId, osmId: 1, at: 0 });
    await ctx.runMutation(components.feedback.items.create, { userId, title: "Dark mode", description: "Please" });
    return files;
  });
}

/** How many rows this person has in every personal table, plus teams they made and Chef requests. */
async function counts(t: T, userId: Id<"users">) {
  return await t.run(async (ctx) => {
    const out: Record<string, number> = {};
    for (const table of TABLES) {
      out[table] = (await ctx.db.query(table).collect()).filter((r) => r.userId === userId).length;
    }
    out.teamsCreated = (await ctx.db.query("teams").collect()).filter((team) => team.createdBy === userId).length;
    out.chefRequests = (await ctx.runQuery(components.feedback.items.listByCreator, { userId, limit: 100 })).length;
    return out;
  });
}

const allZero = (c: Record<string, number>) => Object.fromEntries(Object.keys(c).map((k) => [k, 0]));

describe("account deletion", { timeout: 60_000 }, () => {
  test("covers every table with a userId in the schema", () => {
    const tables = schema.tables as unknown as Record<string, { validator: { json: { value?: Record<string, unknown> } } }>;
    const owned = Object.entries(tables)
      .filter(([, def]) => "userId" in (def.validator.json.value ?? {}))
      .map(([name]) => name)
      .filter((name) => name !== "accountDeletions");
    expect(owned.sort()).toEqual([...TABLES].sort());
  });

  test("signs them out at once, deletes all their data and files, and leaves everyone else's", async () => {
    const { t, alice, bob, aliceId, bobId } = await setup();
    const aliceFiles = await seed(t, aliceId);
    await seed(t, bobId);
    // A team Alice made that Bob joined, and one she's alone in.
    const { teamId, inviteCode } = await alice.action(api.teams.createTeam, { name: "Walkers", colour: "#e67834" });
    await bob.action(api.teams.joinTeam, { code: inviteCode, colour: "#467cba" });
    const solo = await alice.action(api.teams.createTeam, { name: "Just me", colour: "#e67834" });
    const bobBefore = await counts(t, bobId);

    await alice.mutation(api.users.deleteAccount, {});
    // Signed out straight away, before any of the background work.
    expect(await alice.query(api.users.me)).toBeNull();
    await expect(alice.query(api.sync.snapshot, {})).rejects.toThrow("Not signed in");
    await expect(alice.mutation(api.users.deleteAccount, {})).rejects.toThrow("Sign in first");

    await drain(t);
    expect(await counts(t, aliceId)).toEqual(allZero(await counts(t, aliceId)));
    expect(await counts(t, bobId)).toEqual({ ...bobBefore, teamMembers: 1, teamsCreated: 1 });
    await t.run(async (ctx) => {
      for (const file of aliceFiles) expect(await ctx.storage.getUrl(file)).toBeNull();
      // The tombstone keeps nothing about them.
      const user = await ctx.db.get(aliceId);
      expect(user).toMatchObject({ deletedAt: expect.any(Number) });
      expect([user?.name, user?.email, user?.picture, user?.emailVerified]).toEqual([undefined, undefined, undefined, undefined]);
      // Bob keeps the team, now his; the one she was alone in is gone.
      expect(await ctx.db.get(teamId)).toMatchObject({ createdBy: bobId });
      expect(await ctx.db.get(solo.teamId)).toBeNull();
      const deletion = await ctx.db.query("accountDeletions").first();
      expect(deletion).toMatchObject({ userId: aliceId, stage: "done", finishedAt: expect.any(Number) });
    });
    expect((await bob.query(api.teams.myTeams))[0]).toMatchObject({ teamId, createdBy: bobId, members: [{ name: "Bob" }] });
    expect((await bob.query(api.sync.snapshot, {})).walks).toHaveLength(2);
  });

  test("takes several steps for lots of rows", async () => {
    const { t, alice, aliceId } = await setup();
    await t.run(async (ctx) => {
      for (let i = 0; i < BATCH + 50; i++) await ctx.db.insert("secrets", { userId: aliceId, secretId: `s${i}`, foundAt: i });
    });
    await alice.mutation(api.users.deleteAccount, {});
    await t.mutation(internal.accountDeletion.step, { deletionId: (await t.run((ctx) => ctx.db.query("accountDeletions").first()))!._id });
    expect((await counts(t, aliceId)).secrets).toBe(50);
    await drain(t);
    expect((await counts(t, aliceId)).secrets).toBe(0);
  });

  test("the cron picks up a deletion that stopped", async () => {
    const { t, aliceId } = await setup();
    await seed(t, aliceId);
    // As if a deploy had dropped the chain of steps.
    await t.run((ctx) => ctx.db.insert("accountDeletions", {
      userId: aliceId, requestedAt: Date.now(), stage: "walks", passes: 0, deletedRows: 0, lastStepAt: Date.now(),
    }));
    expect(await t.mutation(internal.accountDeletion.resumeStalled, {})).toBe(0);
    vi.advanceTimersByTime(STALL_MS + 1);
    expect(await t.mutation(internal.accountDeletion.resumeStalled, {})).toBe(1);
    await drain(t);
    const left = await counts(t, aliceId);
    expect(left).toEqual(allZero(left));
  });

  test("a file that won't delete keeps its walk for the next try", async () => {
    const { t, alice, aliceId } = await setup();
    const [walkFile] = await seed(t, aliceId, 1);
    await alice.mutation(api.users.deleteAccount, {});
    const deletionId = (await t.run((ctx) => ctx.db.query("accountDeletions").first()))!._id;
    // File storage failing: convex-test sends ctx.storage.delete through the global
    // Convex.asyncSyscall getter, so swapping that out fails every delete.
    type Syscall = (op: string, args: string) => Promise<string>;
    const convex = (globalThis as unknown as { Convex: object }).Convex;
    const real = Object.getOwnPropertyDescriptor(convex, "asyncSyscall")!;
    Object.defineProperty(convex, "asyncSyscall", {
      configurable: true,
      get: () => {
        const syscall = real.get!.call(convex) as Syscall;
        return (op: string, args: string) => (op === "1.0/storageDelete" ? Promise.reject(new Error("Storage is down")) : syscall(op, args));
      },
    });
    try {
      await expect(t.mutation(internal.accountDeletion.step, { deletionId })).rejects.toThrow("Storage is down");
    } finally {
      Object.defineProperty(convex, "asyncSyscall", real);
    }
    // The step rolled back: the walk and its file are both still there, and it isn't done.
    expect((await counts(t, aliceId)).walks).toBe(1);
    await t.run(async (ctx) => {
      expect(await ctx.storage.getUrl(walkFile!)).not.toBeNull();
      expect((await ctx.db.get(deletionId))?.finishedAt).toBeUndefined();
    });
    await drain(t);
    const left = await counts(t, aliceId);
    expect(left).toEqual(allZero(left));
    expect(await t.run((ctx) => ctx.storage.getUrl(walkFile!))).toBeNull();
  });

  test("a file that's already gone doesn't hold the deletion up", async () => {
    const { t, alice, aliceId } = await setup();
    const files = await seed(t, aliceId);
    await t.run(async (ctx) => { for (const file of files) await ctx.storage.delete(file); });
    await alice.mutation(api.users.deleteAccount, {});
    await drain(t);
    const left = await counts(t, aliceId);
    expect(left).toEqual(allZero(left));
    expect(await t.run((ctx) => ctx.db.query("accountDeletions").first())).toMatchObject({ stage: "done", finishedAt: expect.any(Number) });
  });

  test("signing in again through an account merged into theirs puts their details back where they sign in", async () => {
    const { t, alice, aliceId } = await setup();
    // Their Google sign-in still points at the older row that was folded into Alice.
    const oldId = await t.run((ctx) => ctx.db.insert("users", { email: "alice@example.com", emailVerified: true, mergedInto: aliceId }));
    await alice.mutation(api.users.deleteAccount, {});
    await drain(t);
    const provider = {
      name: "google" as const,
      accountId: "google-alice",
      profile: { id: "google-alice", name: "Alice", email: "alice@example.com", emailVerified: true, picture: "https://example.com/new.png" },
    };
    await t.mutation(internal.users.onSignInGoogle, { provider, userId: oldId });
    const profile = { name: "Alice", email: "alice@example.com", picture: "https://example.com/new.png" };
    expect(await t.withIdentity({ subject: oldId }).query(api.users.me)).toEqual(profile);
    expect(await alice.query(api.users.me)).toEqual(profile);
  });

  test("signing in again with the same Apple account starts fresh, once the old data has gone", async () => {
    const { t, alice, aliceId } = await setup();
    await seed(t, aliceId);
    await alice.mutation(api.users.deleteAccount, {});
    const provider = { name: "apple" as const, accountId: "apple-alice", profile: { id: "apple-alice", email: "alice@example.com", emailVerified: true } };
    // Still deleting: come back in a few minutes.
    await expect(t.mutation(internal.users.onSignInApple, { provider, userId: aliceId })).rejects.toThrow("still being deleted");
    await drain(t);
    await t.mutation(internal.users.onSignInApple, { provider, userId: aliceId });
    expect(await alice.query(api.users.me)).toEqual({ name: null, email: "alice@example.com", picture: null });
    expect(await alice.query(api.sync.snapshot, {})).toEqual({ walks: [], places: [], secrets: [], progress: null });
  });

  test("an account merged into theirs is scrubbed too", async () => {
    const { t, alice, aliceId } = await setup();
    const oldId = await t.run((ctx) => ctx.db.insert("users", { name: "Alice (Google)", email: "alice@example.com", emailVerified: true, mergedInto: aliceId }));
    // Merging doesn't move rate-limit rows, so some can still be filed under the old account.
    await t.run((ctx) => ctx.db.insert("placeCalls", { userId: oldId, windowStart: 0, count: 1 }));
    await alice.mutation(api.users.deleteAccount, {});
    await drain(t);
    expect(await t.withIdentity({ subject: oldId }).query(api.users.me)).toBeNull();
    const old = await t.run((ctx) => ctx.db.get(oldId));
    expect(old?.deletedAt).toEqual(expect.any(Number));
    expect([old?.name, old?.email]).toEqual([undefined, undefined]);
    const left = await counts(t, oldId);
    expect(left).toEqual(allZero(left));
  });
});

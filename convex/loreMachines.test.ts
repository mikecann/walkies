/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import feedbackTest from "@convex-dev/feedback/test";
import workflowTest from "@convex-dev/workflow/test";
import { register, throughInternal } from "@convex-dev/state-machines/test";
import type { InternalCtx } from "@convex-dev/state-machines";
import type { GenericMutationCtx } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { machineDiagrams } from "../scripts/machine-diagrams";
import { api, components, internal } from "./_generated/api";
import type { DataModel, Doc, Id } from "./_generated/dataModel";
import { day, queueExpiry, quietRetry } from "./loreConfig";
import { clientStatus, lorePlaceState, type LorePlaceState } from "./loreStates";
import { lorePlace, machines } from "./machines";
import schema from "./schema";

// The research's state machines (loreMachines.ts): the retries and the queue's expiry
// as timers, stale reports from old runs, the links between a place and its secrets,
// and Mike's review. On fake time, with the real scheduler. Workflows are only started
// where a test doesn't move the clock on afterwards, so no pipeline ever runs.

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);
type T = ReturnType<typeof convexTest>;
const somewhere = 4242;
const hour = 60 * 60 * 1000;

/** The longest delay setTimeout takes. Fake timers, like Node, fire a longer one at once. */
const longestDelay = 2 ** 31 - 1;

beforeEach(() => {
  vi.useFakeTimers();
  // convex-test schedules each function with setTimeout, so the queue's 30-day expiry and
  // the 90-day second look would fire straight away. Chained, they fire when they're due.
  // convex-test never clears these (a cancelled job is skipped when it fires), so a chain
  // needs no clearTimeout.
  const fake = globalThis.setTimeout;
  const chained = ((fn: () => void, ms = 0) => ms > longestDelay ? fake(() => chained(fn, ms - longestDelay), longestDelay) : fake(fn, ms)) as typeof setTimeout;
  vi.stubGlobal("setTimeout", chained);
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

function setup() {
  const t = convexTest(schema, modules);
  workflowTest.register(t, "workflow");
  register(t);
  return t;
}

/** Runs `handler` with the ctx of the catalog's internalMutation, as lore.ts's functions get it: how a test sends `server` events. */
const internalRun = <R>(t: T, handler: (ctx: GenericMutationCtx<DataModel> & InternalCtx) => Promise<R>) =>
  t.mutation((ctx) => throughInternal(machines, ctx, (inner) => handler(inner as unknown as GenericMutationCtx<DataModel> & InternalCtx)));
type PlaceEvent = Parameters<typeof lorePlace.send<GenericMutationCtx<DataModel> & InternalCtx>>[2];
const send = (t: T, id: Id<"lorePlaces">, event: PlaceEvent) => internalRun(t, (ctx) => lorePlace.send(ctx, id, event));

/**
 * Moves fake time on by `ms`, letting every scheduled function due on the way run. A
 * delivery can arm the next state's timer, so time moves in steps and each settles.
 * The library's own advance moves 50 ms at a time, too fine for days.
 */
async function advance(t: T, ms: number, step = Math.max(50, Math.floor(ms / 400))) {
  const until = Date.now() + ms;
  for (;;) {
    for (let hop = 0; hop < 4; hop++) {
      vi.advanceTimersByTime(0);
      await t.finishInProgressScheduledFunctions();
    }
    if (Date.now() >= until) return;
    vi.advanceTimersByTime(Math.min(step, until - Date.now()));
  }
}

const researching = (fields: Partial<LorePlaceState & { kind: "researching" }> = {}): LorePlaceState =>
  ({ kind: "researching", manual: false, startedAt: Date.now(), workflowId: "w", ...fields });

/** A place put straight into a state, as the machine would leave it. */
async function addPlace(t: T, fields: Partial<Doc<"lorePlaces">> = {}) {
  return await t.run((ctx) => ctx.db.insert("lorePlaces", {
    osmId: somewhere, name: "Somewhere", state: researching(), stateTimers: [], version: 0, attempts: 1, segment: 1, cost: 0, runCost: 0, ...fields,
  }));
}

async function addEntry(t: T, slug: string, fields: Partial<Doc<"loreEntries">> = {}) {
  return await t.run((ctx) => ctx.db.insert("loreEntries", {
    osmId: somewhere, run: 1, entryId: `osm${somewhere}-${slug}`, title: slug, body: "The jetty is 1,841 m long.", category: "history",
    sticker: "A jetty", sources: [], suburb: "Somewhere", claims: [], sensitive: [], state: { kind: "checking" }, checkNotes: [], factChecked: true, ...fields,
  }));
}

const place = (t: T, id: Id<"lorePlaces">) => t.run(async (ctx) => (await ctx.db.get("lorePlaces", id))!);
const entry = (t: T, id: Id<"loreEntries">) => t.run(async (ctx) => (await ctx.db.get("loreEntries", id))!);
const failedTimers = (t: T) => t.query(internal.machines.failedTimers, {});

describe("a place's retries are its timers", () => {
  test("a first quiet run gets one more look in 90 days, and a second quiet one doesn't", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const t = setup();
    const id = await addPlace(t);
    expect(await t.mutation(internal.loreRun.publish, { osmId: somewhere, run: 1 })).toMatchObject({ status: "quiet" });
    expect((await place(t, id)).state).toMatchObject({ kind: "quietWaiting", retryAt: Date.now() + quietRetry });
    expect((await place(t, id)).stateTimers).toMatchObject([{ event: "RETRY_DUE", dueAt: Date.now() + quietRetry }]);

    await advance(t, quietRetry - hour);
    expect((await place(t, id)).state.kind).toBe("quietWaiting");
    await advance(t, 2 * hour);
    // Back on the queue, remembering how it was if the wait runs out.
    expect((await place(t, id)).state).toMatchObject({ kind: "queued", manual: false, was: { kind: "quiet" } });

    // The hourly tick starts it: run 2, in a budget segment of its own.
    await t.mutation(internal.lore.tick, {});
    expect(await place(t, id)).toMatchObject({ state: { kind: "researching" }, attempts: 2, segment: 2 });
    await t.mutation(internal.loreRun.publish, { osmId: somewhere, run: 2 });
    const after = await place(t, id);
    expect(after.state).toMatchObject({ kind: "quiet" });
    expect(after.stateTimers).toEqual([]);
    expect(await failedTimers(t)).toEqual([]);
  });

  test("with LORE_AUTO off a retry that's due waits a day at a time, and goes on the queue once it's on", async () => {
    const t = setup();
    const id = await addPlace(t);
    await send(t, id, { type: "PUBLISHED", run: 1 });
    const { retryAt } = (await place(t, id)).state as { retryAt: number };
    // In small steps around when it's due, so the day it waits counts from then.
    await advance(t, quietRetry - hour);
    await advance(t, 2 * hour, 60_000);
    const waited = (await place(t, id)).state as { kind: string; retryAt: number };
    expect(waited.kind).toBe("quietWaiting");
    expect(waited.retryAt - (retryAt + day)).toBeGreaterThanOrEqual(0);
    expect(waited.retryAt - (retryAt + day)).toBeLessThanOrEqual(60_000);
    expect((await place(t, id)).stateTimers).toMatchObject([{ event: "RETRY_DUE", dueAt: waited.retryAt }]);
    vi.stubEnv("LORE_AUTO", "1");
    await advance(t, day);
    expect((await place(t, id)).state).toMatchObject({ kind: "queued", was: { kind: "quiet" } });
    expect(await failedTimers(t)).toEqual([]);
  });

  test("a failed run under budget goes back on the queue after a day; over budget or out of runs, it's failed for good", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const t = setup();
    const finish = (osmId: number, run: number, error: string) =>
      t.mutation(internal.lore.runFinished, { workflowId: "w" as never, result: { kind: "failed", error }, context: { osmId, run } });
    const id = await addPlace(t);
    await finish(somewhere, 1, "OpenRouter is down");
    expect((await place(t, id)).state).toMatchObject({ kind: "failedWaiting", error: "OpenRouter is down", retryAt: Date.now() + day });
    await advance(t, day + hour);
    expect((await place(t, id)).state).toMatchObject({ kind: "queued", was: { kind: "failed", error: "OpenRouter is down" } });
    // Run 2 (of maxAttempts) fails too.
    await send(t, id, { type: "START", workflowId: "w2" });
    await finish(somewhere, 2, "OpenRouter is still down");
    expect((await place(t, id)).state).toMatchObject({ kind: "failed", error: "OpenRouter is still down" });
    expect((await place(t, id)).stateTimers).toEqual([]);

    const broke = await addPlace(t, { osmId: 5 });
    await finish(5, 1, "Over budget: this run has spent $6.00, and stops at $6.");
    expect((await place(t, broke)).state.kind).toBe("failed");
    expect(await failedTimers(t)).toEqual([]);
  });
});

describe("old runs and the place's secrets", () => {
  test("a report from an earlier run is refused, and the current run's secrets are left alone", async () => {
    const t = setup();
    const id = await addPlace(t, { attempts: 2 });
    const current = await addEntry(t, "current", { run: 2 });
    const guard = ["That report is from an earlier run of this place."];
    expect(await send(t, id, { type: "PUBLISHED", run: 1 })).toEqual({ status: "rejected", code: "GUARD_BLOCKED", reasons: guard });
    expect(await send(t, id, { type: "RUN_FAILED", run: 1, error: "late" })).toEqual({ status: "rejected", code: "GUARD_BLOCKED", reasons: guard });
    // The real callers: run 1's workflow finishing late, and its last step.
    await t.mutation(internal.lore.runFinished, { workflowId: "w1" as never, result: { kind: "failed", error: "late" }, context: { osmId: somewhere, run: 1 } });
    expect(await t.mutation(internal.loreRun.publish, { osmId: somewhere, run: 1 })).toMatchObject({ status: "stale" });
    expect((await place(t, id)).state.kind).toBe("researching");
    expect((await entry(t, current)).state).toEqual({ kind: "checking" });
    expect(await t.run((ctx) => ctx.db.query("loreJournals").collect())).toEqual([]);
    // Nothing about them in the place's history: a refused send is the caller's to see.
    expect((await t.query(internal.lore.history, { osmId: somewhere })).page).toEqual([]);
  });

  test("a run that stops drops only its own secrets still being checked, and their stickers", async () => {
    const t = setup();
    const id = await addPlace(t, { attempts: 2 });
    const sticker = await t.run((ctx) => ctx.storage.store(new Blob(["png"])));
    const checking = await addEntry(t, "checking", { run: 2, stickerFile: sticker });
    const live = await addEntry(t, "live", { run: 2, state: { kind: "auto" } });
    const older = await addEntry(t, "older", { run: 1 });
    await send(t, id, { type: "RUN_FAILED", run: 2, error: "boom" });
    expect(await entry(t, checking)).toMatchObject({ state: { kind: "dropped", by: "run stopped" }, checkNotes: ["The run stopped before it finished."] });
    expect((await entry(t, checking)).stickerFile).toBeUndefined();
    expect(await t.run((ctx) => ctx.db.system.get(sticker))).toBeNull();
    expect((await entry(t, live)).state).toEqual({ kind: "auto" });
    expect((await entry(t, older)).state).toEqual({ kind: "checking" });
  });

  test("a resume needs the run's journal, brings back only drops that weren't the secret's fault, and goes back to how it was if it can't start", async () => {
    const t = setup();
    const failed: LorePlaceState = { kind: "failed", startedAt: 1, finishedAt: 2, error: "boom" };
    const id = await addPlace(t, { state: failed });
    const budget = await addEntry(t, "budget", { state: { kind: "dropped", by: "budget" }, factChecked: false });
    const madeUp = await addEntry(t, "made-up", { state: { kind: "dropped", by: "quote check" } });
    expect(await send(t, id, { type: "RESUME", from: "lorePipeline:write" })).toMatchObject({
      status: "rejected", reasons: ["The last run's journal has been deleted, so it can't be resumed."],
    });
    await expect(t.mutation(internal.lore.resume, { osmId: somewhere, from: "lorePipeline:write" })).rejects.toThrow(/journal has been deleted/);

    await t.run((ctx) => ctx.db.insert("loreJournals", { osmId: somewhere, run: 1, workflowId: "gone", until: Date.now() + day }));
    expect(await send(t, id, { type: "RESUME", from: "lorePipeline:write" })).toMatchObject({ status: "done", to: "queued" });
    expect((await place(t, id)).state).toMatchObject({ kind: "queued", manual: true, resume: "lorePipeline:write", was: failed });
    expect(await entry(t, budget)).toMatchObject({ state: { kind: "checking" }, checkNotes: ["Brought back by lore:resume from lorePipeline:write."] });
    expect((await entry(t, madeUp)).state).toEqual({ kind: "dropped", by: "quote check" });

    // Its workflow is gone, so the restart fails, and it's failed as it was.
    await t.mutation(internal.lore.tick, {});
    expect((await place(t, id)).state).toEqual(failed);
    expect((await place(t, id)).stateTimers).toEqual([]);
  });
});

describe("the queue's expiry", () => {
  test("a walk's place leaves the queue after 30 days: never researched, it's as if nobody walked there; researched, it's as it was; Mike's stays", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const t = setup();
    // Both slots busy, so nothing starts.
    await addPlace(t, { osmId: 1, runCost: 5.9 });
    await addPlace(t, { osmId: 2, runCost: 5.9 });
    const [aliceId, bobId] = await t.run((ctx) => Promise.all([ctx.db.insert("users", { name: "Alice" }), ctx.db.insert("users", { name: "Bob" })]));
    const placeId = await t.run(async (ctx) => ctx.db.insert("places", {
      userId: aliceId, clientId: "p", name: "Somewhere", createdAt: 0, updatedAt: 0, file: await ctx.storage.store(new Blob(["{}"])),
    }));
    const walk = (userId: Id<"users">) => t.mutation(internal.lore.noteWalked, { userId, placeId, osmId: 3, name: "Somewhere", walkedTiles: 5 });
    expect(await walk(aliceId)).toBe("queued");
    expect(await t.mutation(internal.lore.queueManual, { osmId: 5 })).toBe("queued");
    // A quiet place whose second look comes due in an hour.
    const quiet = await addPlace(t, { osmId: 4, state: { kind: "quietWaiting", startedAt: 0, finishedAt: 0, retryAt: Date.now() + hour } });
    await internalRun(t, (ctx) => lorePlace.armTimers(ctx, quiet));

    await advance(t, queueExpiry + 2 * hour);
    const byOsm = async (osmId: number) => (await t.run((ctx) => ctx.db.query("lorePlaces").collect())).find((r) => r.osmId === osmId)!;
    expect((await byOsm(3)).state).toEqual({ kind: "expired", expiredAt: expect.any(Number) });
    expect((await byOsm(4)).state).toEqual({ kind: "quiet", startedAt: 0, finishedAt: 0 });
    expect((await byOsm(5)).state).toMatchObject({ kind: "queued", manual: true });
    // The phones hear nothing's there, and the next walk can queue it again.
    expect(await t.withIdentity({ subject: aliceId }).query(api.lore.forPlace, { osmId: 3 })).toEqual({ status: "none", version: 0, entries: [] });
    expect(await walk(bobId)).toBe("queued");
    expect((await byOsm(3)).state).toMatchObject({ kind: "queued", requestedBy: bobId });
    expect(await failedTimers(t)).toEqual([]);
  });
});

test("an account's deletion forgets it queued places, wherever they've got to", async () => {
  const t = setup();
  const aliceId = await t.run((ctx) => ctx.db.insert("users", { name: "Alice" }));
  const waiting = await addPlace(t, { osmId: 1, state: { kind: "queued", queuedAt: 0, manual: false, requestedBy: aliceId } });
  const going = await addPlace(t, { osmId: 2, state: researching({ requestedBy: aliceId }) });
  expect(await t.mutation(internal.lore.forgetRequester, { userId: aliceId, limit: 10 })).toBe(2);
  expect((await place(t, waiting)).state).toEqual({ kind: "queued", queuedAt: 0, manual: false });
  expect((await place(t, going)).state).not.toHaveProperty("requestedBy");
  expect(await t.mutation(internal.lore.forgetRequester, { userId: aliceId, limit: 10 })).toBe(0);
});

describe("Mike's review", () => {
  test("a secret already where it's sent is left be, one that isn't up for review says so, and each change bumps the version", async () => {
    const t = setup();
    const id = await addPlace(t, { state: { kind: "ready", startedAt: 0, finishedAt: 0 }, version: 4 });
    await addEntry(t, "approved", { state: { kind: "approved" } });
    await addEntry(t, "pending", { state: { kind: "pending" } });
    await addEntry(t, "checking");
    await addEntry(t, "dropped", { state: { kind: "dropped", by: "rules" } });
    const review = (fn: "approve" | "hide", slug: string) => t.mutation(internal.lore[fn], { entryId: `osm${somewhere}-${slug}` });
    expect(await review("approve", "approved")).toBeNull();
    expect((await place(t, id)).version).toBe(4);
    await expect(review("approve", "checking")).rejects.toThrow("That secret is checking, not up for review");
    await expect(review("hide", "dropped")).rejects.toThrow("That secret is dropped, not up for review");
    expect(await review("approve", "pending")).toBeNull();
    expect((await place(t, id)).version).toBe(5);
    // The same from the app, for Chef's admin.
    feedbackTest.register(t);
    const adminId = await t.run(async (ctx) => {
      const userId = await ctx.db.insert("users", { name: "Mike" });
      await ctx.runMutation(components.feedback.users.setRole, { userId, role: "admin" });
      return userId;
    });
    const admin = t.withIdentity({ subject: adminId });
    expect(await admin.mutation(api.lore.adminHide, { entryId: `osm${somewhere}-pending` })).toBeNull();
    expect(await admin.mutation(api.lore.adminHide, { entryId: `osm${somewhere}-pending` })).toBeNull();
    expect((await place(t, id)).version).toBe(6);
    await expect(admin.mutation(api.lore.adminApprove, { entryId: `osm${somewhere}-dropped` })).rejects.toThrow("That secret is dropped, not up for review");
  });
});

test("the phones get a status they know for every state", () => {
  const kinds = lorePlaceState.members.map((member) => member.fields.kind.value);
  const sample = (kind: string) => ({ kind, queuedAt: 0, manual: false, startedAt: 0, finishedAt: 0, workflowId: "w", retryAt: 0, error: "", expiredAt: 0 }) as LorePlaceState;
  expect(Object.fromEntries(kinds.map((kind) => [kind, clientStatus(sample(kind))]))).toEqual({
    queued: "queued", researching: "researching", ready: "ready", quietWaiting: "quiet", quiet: "quiet",
    failedWaiting: "failed", failed: "failed", expired: "none",
  });
});

test("docs/machines.md is drawn from the machines as they are (npm run diagrams)", () => {
  const files = import.meta.glob<string>("../docs/machines.md", { eager: true, query: "?raw", import: "default" });
  expect(Object.values(files)[0]).toBe(machineDiagrams());
});

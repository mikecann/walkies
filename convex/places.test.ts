/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import schema from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);

afterEach(() => { vi.useRealTimers(); });

async function signedIn() {
  const t = convexTest(schema, modules);
  const userId = await t.run((ctx) => ctx.db.insert("users", { name: "Mike" }));
  return { t, client: t.withIdentity({ subject: userId }) };
}

const rows = (t: ReturnType<typeof convexTest>) =>
  t.run((ctx) => ctx.db.query("placeData").collect());

test("warming queues each place once and starts a single worker", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  await client.mutation(internal.places.enqueue, { osmIds: [3, 1, 2, 1] });
  await client.mutation(internal.places.enqueue, { osmIds: [2, 4] });
  const all = await rows(t);
  const places = all.filter((r) => r.osmId > 0);
  expect(places.map((r) => r.osmId).sort()).toEqual([1, 2, 3, 4]);
  expect(places.every((r) => r.queuedAt !== undefined && r.attempts === 0)).toBe(true);
  // One worker heartbeat, however many lists arrive.
  expect(all.filter((r) => r.osmId === -1)).toHaveLength(1);
});

test("the worker takes places one at a time, oldest first, then stops", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  await client.mutation(internal.places.enqueue, { osmIds: [7] });
  // Moves the clock without running the scheduled worker, which would go to OSM.
  vi.setSystemTime(Date.now() + 10);
  await client.mutation(internal.places.enqueue, { osmIds: [5] });
  const first = await t.mutation(internal.places.claimNext, {});
  expect(first).toMatchObject({ kind: "fetch", osmId: 7 });
  const second = await t.mutation(internal.places.claimNext, {});
  expect(second).toMatchObject({ kind: "fetch", osmId: 5 });
  expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "done" });
  const worker = (await rows(t)).find((r) => r.osmId === -1);
  expect(worker?.fetchingAt).toBeUndefined();
});

test("a failed warm backs off and is retried a few times, then left for places:get", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  await client.mutation(internal.places.enqueue, { osmIds: [9] });
  for (const wait of [60_000, 5 * 60_000, 30 * 60_000]) {
    const next = await t.mutation(internal.places.claimNext, {});
    expect(next.kind).toBe("fetch");
    if (next.kind !== "fetch") return;
    await t.mutation(internal.places.finish, { osmId: 9, lease: next.lease });
    const waiting = await t.mutation(internal.places.claimNext, {});
    expect(waiting).toEqual({ kind: "wait", ms: wait });
    vi.setSystemTime(Date.now() + wait);
  }
  const last = await t.mutation(internal.places.claimNext, {});
  if (last.kind !== "fetch") throw new Error("expected a final attempt");
  await t.mutation(internal.places.finish, { osmId: 9, lease: last.lease });
  expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "done" });
  const row = (await rows(t)).find((r) => r.osmId === 9);
  expect([row?.queuedAt, row?.attempts, row?.fetchingAt]).toEqual([undefined, undefined, undefined]);
});

test("a place someone is already fetching waits instead of a second Overpass query", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  await t.mutation(internal.places.claim, { osmId: 11 });
  await client.mutation(internal.places.enqueue, { osmIds: [11] });
  expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "skip" });
  const row = (await rows(t)).find((r) => r.osmId === 11);
  expect(row?.queuedAt).toBe(Date.now() + 30_000);
});

test("places:get answers from the cache, but only so many times a minute", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  const file = await t.run((ctx) => ctx.storage.store(new Blob(["{}"])));
  await t.run((ctx) => ctx.db.insert("placeData", { osmId: 21, name: "Home", fetchedAt: Date.now(), version: 1, file }));
  for (let i = 0; i < 30; i++) {
    expect((await client.action(api.places.get, { osmId: 21 })).url).toBeTruthy();
  }
  await expect(client.action(api.places.get, { osmId: 21 })).rejects.toThrow(/Too many/);
  // Warming counts towards the same limit.
  await expect(client.action(api.places.warm, { osmIds: [22] })).rejects.toThrow(/Too many/);
  vi.setSystemTime(Date.now() + 60_000);
  expect((await client.action(api.places.get, { osmId: 21 })).url).toBeTruthy();
});

test("each user has their own limit", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  const other = t.withIdentity({ subject: await t.run((ctx) => ctx.db.insert("users", { name: "Seth" })) });
  for (let i = 0; i < 30; i++) await client.mutation(internal.places.allowCall, {});
  await expect(client.mutation(internal.places.allowCall, {})).rejects.toThrow(/Too many/);
  await other.mutation(internal.places.allowCall, {});
  await expect(t.mutation(internal.places.allowCall, {})).rejects.toThrow(/Not signed in/);
});

test("only one Overpass query runs at a time, and a crashed one frees the slot", async () => {
  vi.useFakeTimers();
  const { t } = await signedIn();
  const first = Date.now();
  expect(await t.mutation(internal.places.takeOverpass, { lease: first })).toBe(0);
  expect(await t.mutation(internal.places.takeOverpass, { lease: first + 1 })).toBeGreaterThan(0);
  // Releasing someone else's lease does nothing.
  await t.mutation(internal.places.releaseOverpass, { lease: first + 1 });
  expect(await t.mutation(internal.places.takeOverpass, { lease: first + 2 })).toBeGreaterThan(0);
  await t.mutation(internal.places.releaseOverpass, { lease: first });
  expect(await t.mutation(internal.places.takeOverpass, { lease: first + 3 })).toBe(0);
  vi.setSystemTime(first + 3 + 5 * 60 * 1000 + 1);
  expect(await t.mutation(internal.places.takeOverpass, { lease: Date.now() })).toBe(0);
});

test("the slot never shows up as a place on the warm queue", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  await t.mutation(internal.places.takeOverpass, { lease: Date.now() });
  await client.mutation(internal.places.enqueue, { osmIds: [] });
  expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "done" });
});

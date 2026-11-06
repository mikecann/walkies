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
  // Each stays on the queue until its fetch finishes, in case the worker dies mid-fetch.
  for (const [osmId, next] of [[7, first], [5, second]] as const) {
    if (next.kind !== "fetch") throw new Error("expected a fetch");
    const file = await t.run((ctx) => ctx.storage.store(new Blob(["{}"])));
    expect(await t.mutation(internal.places.finish, { osmId, lease: next.lease, name: "Done", file })).toBe(true);
  }
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
  await t.run((ctx) => ctx.db.insert("placeData", { osmId: 21, name: "Home", fetchedAt: Date.now(), version: 2, file }));
  for (let i = 0; i < 30; i++) {
    const cached = await client.action(api.places.get, { osmId: 21 });
    expect(cached.url).toBeTruthy();
    expect(cached.version).toBe(2);
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
  vi.setSystemTime(first + 3 + 7 * 60 * 1000 + 1);
  expect(await t.mutation(internal.places.takeOverpass, { lease: Date.now() })).toBe(0);
});

test("the slot never shows up as a place on the warm queue", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  await t.mutation(internal.places.takeOverpass, { lease: Date.now() });
  await client.mutation(internal.places.enqueue, { osmIds: [] });
  expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "done" });
});

test("streets cached by an older version are fetched again and can all be requeued", async () => {
  vi.useFakeTimers();
  const { t } = await signedIn();
  const file = await t.run((ctx) => ctx.storage.store(new Blob(["{}"])));
  await t.run(async (ctx) => {
    await ctx.db.insert("placeData", { osmId: 31, name: "Old", fetchedAt: Date.now(), version: 1, file });
    await ctx.db.insert("placeData", { osmId: 32, name: "Current", fetchedAt: Date.now(), version: 2, file });
    await ctx.db.insert("placeData", { osmId: 33, name: "Never fetched", fetchedAt: 0, version: 2 });
  });
  // Opening an old place fetches it again rather than handing over the old file.
  expect(await t.mutation(internal.places.claim, { osmId: 31 })).toMatchObject({ kind: "fetch" });
  expect(await t.mutation(internal.places.claim, { osmId: 32 })).toMatchObject({ kind: "ready" });
  await t.run(async (ctx) => {
    const row = (await ctx.db.query("placeData").collect()).find((r) => r.osmId === 31)!;
    await ctx.db.patch("placeData", row._id, { fetchingAt: undefined });
  });
  expect(await t.mutation(internal.places.requeueMissing, {})).toEqual({ queued: 2 });
  const queued = (await rows(t)).filter((r) => r.osmId > 0 && r.queuedAt !== undefined).map((r) => r.osmId).sort();
  expect(queued).toEqual([31, 33]);
});

// Answers Nominatim with a small square suburb and Overpass with `overpass`, or a 500.
function stubOSM(overpass: (endpoint: string, query: string) => unknown) {
  const calls: string[] = [];
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push(url);
    if (url.includes("nominatim")) {
      const ring = [[115, -33], [115.01, -33], [115.01, -33.01], [115, -33.01], [115, -33]];
      return Response.json([{ osm_type: "relation", osm_id: 9, name: "Tiny", geojson: { type: "Polygon", coordinates: [ring] } }]);
    }
    const body = overpass(url, new URLSearchParams(String(init?.body ?? "")).get("data") ?? "");
    if (typeof body === "number") return new Response("error", { status: body });
    return body === undefined ? new Response("busy", { status: 500 }) : Response.json(body);
  });
  return calls;
}
afterEach(() => { vi.unstubAllGlobals(); });

const overpassAnswer = {
  elements: [
    { type: "way", tags: { highway: "residential", foot: "yes", name: "Queen St" }, geometry: [{ lat: -33.0011111111, lon: 115.001 }, { lat: -33.002, lon: 115.002 }] },
    { type: "way", tags: { highway: "motorway" }, geometry: [{ lat: -33.003, lon: 115.003 }, { lat: -33.004, lon: 115.004 }] },
  ],
};

test("the Overpass response is parsed and stored by a Node action, falling back to the second server", async () => {
  // Node actions get far more memory than the default runtime's 64 MB, which a big
  // suburb's `out geom` response ran out of (WALKIES-6).
  const source = import.meta.glob<string>("./placeStreets.ts", { eager: true, query: "?raw", import: "default" });
  expect(Object.values(source)[0]).toMatch(/^"use node";/);
  const { t } = await signedIn();
  const calls = stubOSM((url) => url.includes("overpass-api.de") ? undefined : overpassAnswer);
  const boundary = [[[[115, -33], [115.01, -33], [115.01, -33.01], [115, -33]]]];
  const file = await t.action(internal.placeStreets.download, { boundary: JSON.stringify(boundary), deadline: Date.now() + 9 * 60 * 1000 });
  const stored = await t.run(async (ctx) => JSON.parse(await (await ctx.storage.get(file))!.text()));
  expect(stored).toEqual({ boundary, ways: [{ highway: "residential", foot: "yes", points: [[-33.001111, 115.001], [-33.002, 115.002]] }] });
  expect(calls).toHaveLength(2);
});

test("places:get fetches and caches a place it hasn't got", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  stubOSM(() => overpassAnswer);
  const cached = await client.action(api.places.get, { osmId: 9 });
  expect(cached.url).toBeTruthy();
  const row = (await rows(t)).find((r) => r.osmId === 9);
  expect(row).toMatchObject({ name: "Tiny", version: 2 });
  expect(row?.file).toBeDefined();
  expect(row?.fetchingAt).toBeUndefined();
});

test("the worker carries on after a place's street fetch fails", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  stubOSM(() => undefined);
  await client.mutation(internal.places.enqueue, { osmIds: [9] });
  await t.action(internal.places.drain, {});
  const row = (await rows(t)).find((r) => r.osmId === 9);
  expect(row).toMatchObject({ queuedAt: Date.now() + 60_000, attempts: 1 });
  expect(row?.fetchingAt).toBeUndefined();
  const scheduled = await t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect());
  expect(scheduled.filter((s) => s.name.includes("drain") && s.state.kind === "pending").length).toBeGreaterThan(0);
});

test("a place whose fetch died with the worker stays queued, and each death counts as a try", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  await client.mutation(internal.places.enqueue, { osmIds: [9] });
  // Four tries, like a fetch that fails cleanly, and finish() never runs for any of them.
  for (let attempt = 0; attempt < 4; attempt++) {
    expect(await t.mutation(internal.places.claimNext, {})).toMatchObject({ kind: "fetch", osmId: 9 });
    expect((await rows(t)).find((r) => r.osmId === 9)?.attempts).toBe(attempt);
    // Not handed out again while the dead fetch's lease could still be live.
    expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "wait", ms: 10 * 60 * 1000 });
    vi.setSystemTime(Date.now() + 10 * 60 * 1000);
  }
  expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "skip" });
  expect(await t.mutation(internal.places.claimNext, {})).toEqual({ kind: "done" });
  const row = (await rows(t)).find((r) => r.osmId === 9);
  expect([row?.queuedAt, row?.attempts, row?.fetchingAt]).toEqual([undefined, undefined, undefined]);
});

test("a worker that died is started again while places are still queued", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  const worker = async () => (await rows(t)).find((r) => r.osmId === -1);
  // Nothing queued: nothing to start.
  await t.mutation(internal.places.resumeWorker, {});
  expect(await worker()).toBeUndefined();
  await client.mutation(internal.places.enqueue, { osmIds: [9] });
  await t.mutation(internal.places.claimNext, {});
  const heartbeat = (await worker())?.fetchingAt;
  // Still within its lease, it might be running, so it's left alone.
  vi.setSystemTime(Date.now() + 60_000);
  await t.mutation(internal.places.resumeWorker, {});
  expect((await worker())?.fetchingAt).toBe(heartbeat);
  vi.setSystemTime(Date.now() + 10 * 60 * 1000);
  await t.mutation(internal.places.resumeWorker, {});
  expect((await worker())?.fetchingAt).toBe(Date.now());
});

test("a place the old worker dropped mid-fetch goes back on the queue with requeueMissing", async () => {
  vi.useFakeTimers();
  const { t } = await signedIn();
  // What the previous code left when its worker ran out of memory: off the queue, still marked as fetching.
  await t.run((ctx) => ctx.db.insert("placeData", { osmId: 9, name: "", fetchedAt: 0, version: 2, fetchingAt: Date.now(), attempts: 0 }));
  vi.setSystemTime(Date.now() + 10 * 60 * 1000);
  expect(await t.mutation(internal.places.requeueMissing, {})).toEqual({ queued: 1 });
  expect(await t.mutation(internal.places.claimNext, {})).toMatchObject({ kind: "fetch", osmId: 9 });
  // The fetch that died counts as one of its tries.
  expect((await rows(t)).find((r) => r.osmId === 9)?.attempts).toBe(1);
});

test("a suburb too heavy for one Overpass query is fetched in quarters and stored as one file", async () => {
  const { t } = await signedIn();
  const queries: string[] = [];
  stubOSM((_, query) => {
    queries.push(query);
    // The whole suburb times out at Overpass's gateway (WALKIES-8); its quarters don't.
    if (queries.length === 1) return 504;
    const [south, west] = query.match(/\((-?[\d.]+),(-?[\d.]+),/)!.slice(1).map(Number);
    return { elements: [{ type: "way", id: queries.length, tags: { highway: "footway" }, geometry: [{ lat: south, lon: west }, { lat: south + 0.001, lon: west + 0.001 }] }] };
  });
  const boundary = [[[[115, -33], [115.01, -33], [115.01, -33.01], [115, -33]]]];
  const file = await t.action(internal.placeStreets.download, { boundary: JSON.stringify(boundary), deadline: Date.now() + 9 * 60 * 1000 });
  const stored = await t.run(async (ctx) => JSON.parse(await (await ctx.storage.get(file))!.text()));
  expect(queries).toHaveLength(5);
  const box = (query: string) => query.match(/\(([-\d.,]+)\);/)![1];
  expect(box(queries[0])).toBe("-33.01,115,-33,115.01");
  expect(queries.slice(1).map(box).sort()).toEqual([
    "-33.005,115,-33,115.005", "-33.005,115.005,-33,115.01", "-33.01,115,-33.005,115.005", "-33.01,115.005,-33.005,115.01",
  ].sort());
  expect(stored.boundary).toEqual(boundary);
  expect(stored.ways).toHaveLength(4);
});

const square = [[[[115, -33], [115.01, -33], [115.01, -33.01], [115, -33]]]];
const footway = (id: number, query: string) => {
  const [south, west] = query.match(/\((-?[\d.]+),(-?[\d.]+),/)!.slice(1).map(Number);
  return { elements: [{ type: "way", id, tags: { highway: "footway" }, geometry: [{ lat: south, lon: west }, { lat: south + 0.001, lon: west + 0.001 }] }] };
};

test("a server stuck on 504s is passed over for the other one", async () => {
  const { t } = await signedIn();
  const asked: string[] = [];
  stubOSM((url, query) => {
    asked.push(new URL(url).host);
    return url.includes("overpass-api.de") ? 504 : footway(asked.length, query);
  });
  const file = await t.action(internal.placeStreets.download, { boundary: JSON.stringify(square), deadline: Date.now() + 9 * 60 * 1000 });
  const stored = await t.run(async (ctx) => JSON.parse(await (await ctx.storage.get(file))!.text()));
  // The first 504 splits the suburb, and every quarter goes to the server that's answering.
  expect(asked).toEqual(["overpass-api.de", "maps.mail.ru", "maps.mail.ru", "maps.mail.ru", "maps.mail.ru"]);
  expect(stored.ways).toHaveLength(4);
});

test("a broken answer from one server means asking the other", async () => {
  const { t } = await signedIn();
  stubOSM((url, query) => url.includes("overpass-api.de") ? {} : footway(1, query));
  const file = await t.action(internal.placeStreets.download, { boundary: JSON.stringify(square), deadline: Date.now() + 9 * 60 * 1000 });
  const stored = await t.run(async (ctx) => JSON.parse(await (await ctx.storage.get(file))!.text()));
  expect(stored.ways).toHaveLength(1);
});

test("no Overpass request starts once the caller's time is nearly up", async () => {
  const { t } = await signedIn();
  const calls = stubOSM(() => ({ elements: [] }));
  await expect(t.action(internal.placeStreets.download, { boundary: JSON.stringify(square), deadline: Date.now() + 25_000 })).rejects.toThrow(/Ran out of time/);
  expect(calls).toHaveLength(0);
});

test("Overpass saying it timed out, or our own timeout firing, splits the box too", async () => {
  const { t } = await signedIn();
  let n = 0;
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    if (String(input).includes("nominatim")) throw new Error("not used");
    n++;
    if (n === 1) return Response.json({ remark: "runtime error: timeout", elements: [] });
    if (n === 2) throw Object.assign(new Error("The operation was aborted"), { name: "AbortError" });
    return Response.json(footway(n, new URLSearchParams(String(init?.body)).get("data")!));
  });
  const file = await t.action(internal.placeStreets.download, { boundary: JSON.stringify(square), deadline: Date.now() + 9 * 60 * 1000 });
  const stored = await t.run(async (ctx) => JSON.parse(await (await ctx.storage.get(file))!.text()));
  // The whole box timed out, then its first quarter did, so that quarter came in four.
  expect(n).toBe(1 + 1 + 4 + 3);
  expect(stored.ways).toHaveLength(7);
});

test("a bad way from one server means asking the other, and a stuck server is passed over", async () => {
  const { t } = await signedIn();
  const asked: string[] = [];
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    asked.push(new URL(String(input)).host);
    const query = new URLSearchParams(String(init?.body)).get("data")!;
    if (asked.length === 1) return Response.json({ elements: [{ type: "way", id: 1, tags: { highway: "footway" }, geometry: [{ lat: null, lon: 115 }] }] });
    if (asked.length === 2) throw Object.assign(new Error("The operation was aborted"), { name: "AbortError" });
    return Response.json(footway(asked.length, query));
  });
  await t.action(internal.placeStreets.download, { boundary: JSON.stringify(square), deadline: Date.now() + 9 * 60 * 1000 });
  // The bad answer sent it to the other server, which got stuck, so the box was split
  // and its quarters went back to the first.
  expect(asked).toEqual(["overpass-api.de", "maps.mail.ru", "overpass-api.de", "overpass-api.de", "overpass-api.de", "overpass-api.de"]);
});

// Nominatim's answer for a place the size of a state (about 1,000 km by 1,000 km).
function stubHugePlace() {
  const calls: string[] = [];
  vi.stubGlobal("fetch", async (input: string | URL) => {
    const url = String(input);
    calls.push(url);
    if (!url.includes("nominatim")) throw new Error("Overpass shouldn't be asked");
    const ring = [[115, -35], [125, -35], [125, -25], [115, -25], [115, -35]];
    return Response.json([{ osm_type: "relation", osm_id: 80500, name: "Australia", geojson: { type: "Polygon", coordinates: [ring] } }]);
  });
  return calls;
}

test("a place far too big to walk round (a state, a country) is refused before Overpass is asked", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  const calls = stubHugePlace();
  await expect(client.action(api.places.get, { osmId: 80500 })).rejects.toThrow(/too big/);
  expect(calls.every((url) => url.includes("nominatim"))).toBe(true);
  const row = (await rows(t)).find((r) => r.osmId === 80500);
  expect(row?.fetchingAt).toBeUndefined();
});

test("the warm queue drops a place that's far too big rather than retrying it", async () => {
  vi.useFakeTimers();
  const { t, client } = await signedIn();
  stubHugePlace();
  await client.mutation(internal.places.enqueue, { osmIds: [80500] });
  await t.action(internal.places.drain, {});
  const row = (await rows(t)).find((r) => r.osmId === 80500);
  expect([row?.queuedAt, row?.attempts, row?.fetchingAt]).toEqual([undefined, undefined, undefined]);
});

test("a request cut short by the deadline says it ran out of time instead of splitting", async () => {
  const { t } = await signedIn();
  let n = 0;
  vi.stubGlobal("fetch", async () => { n++; throw Object.assign(new Error("This operation was aborted"), { name: "AbortError" }); });
  // 60 s left: past the 20 s kept for saving, so the request's timeout is cut below 135 s.
  await expect(t.action(internal.placeStreets.download, { boundary: JSON.stringify(square), deadline: Date.now() + 60_000 })).rejects.toThrow(/Ran out of time/);
  expect(n).toBe(1);
});

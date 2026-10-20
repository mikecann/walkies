// Offline checks: real parsing and registered handlers, with an in-memory Convex
// context. No deployment, account data or public OSM requests are involved.
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { build } from "esbuild";
import { getFunctionName } from "convex/server";

const root = new URL("../", import.meta.url);
const output = new URL("build/places-tests/", root);
await mkdir(output, { recursive: true });
for (const name of ["placeData", "places"]) {
  await build({
    entryPoints: [new URL(`convex/${name}.ts`, root).pathname],
    outfile: new URL(`${name}.mjs`, output).pathname,
    bundle: true, platform: "node", format: "esm", packages: "external",
    plugins: [{ name: "test-auth", setup(build) {
      build.onResolve({ filter: /^\.\/users$/ }, () => ({ path: "auth", namespace: "test" }));
      build.onLoad({ filter: /.*/, namespace: "test" }, () => ({ contents: "export async function currentUserId(ctx) { return ctx.userId ?? null; }" }));
    } }],
  });
}
const { boundaryFromNominatim, walkableQuery, waysFromOverpass } = await import(new URL("placeData.mjs", output));
const places = await import(new URL("places.mjs", output));
const ring = [[115.380000123, -33.640000123], [115.39, -33.64], [115.39, -33.63], [115.38, -33.640000123]];
const hole = [[115.384, -33.636], [115.386, -33.636], [115.386, -33.634], [115.384, -33.636]];
const nominatim = [{ osm_type: "relation", osm_id: 123, name: "Geographe", geojson: { type: "Polygon", coordinates: [ring, hole] } }];
const parsed = boundaryFromNominatim(nominatim, 123);
assert.equal(parsed.name, "Geographe");
assert.deepEqual(parsed.boundary[0][0][0], [115.38, -33.64]);
assert.deepEqual(parsed.boundary[0][1], hole);
assert.deepEqual(boundaryFromNominatim([{ ...nominatim[0], geojson: { type: "MultiPolygon", coordinates: [[ring], [ring, hole]] } }], 123).boundary.length, 2);
assert.throws(() => boundaryFromNominatim(nominatim, 999));
assert.throws(() => boundaryFromNominatim([{ ...nominatim[0], geojson: { type: "Point", coordinates: [1, 2] } }], 123));
assert.throws(() => boundaryFromNominatim([{ ...nominatim[0], geojson: { type: "Polygon", coordinates: [[[181, -33], ...ring]] } }], 123));
const query = walkableQuery(parsed.boundary);
assert.ok(query.includes('(\u002d33.64,115.38,\u002d33.63,115.39)'));
for (const tag of ['["highway"]', '["access"!~"^(private|no)$"]', '["foot"!~"^(private|no)$"]', 'motorway_link', 'bus_guideway', 'out geom;']) assert.ok(query.includes(tag));
const way = (tags) => ({ type: "way", tags, geometry: [{ lat: -33.6381234567, lon: 115.3861234567 }, { lat: -33.637, lon: 115.387 }] });
const overpass = { elements: [
  way({ highway: "residential", name: "unneeded" }),
  way({ highway: "footway", footway: "sidewalk", foot: "yes" }),
  way({ highway: "service", service: "driveway", access: "destination" }),
  way({ highway: "service", service: "parking_aisle" }),
  way({ highway: "path" }),
  ...["motorway", "motorway_link", "construction", "proposed", "raceway", "bus_guideway", "abandoned", "razed"].map((highway) => way({ highway })),
  way({ highway: "path", access: "private" }), way({ highway: "path", access: "no" }),
  way({ highway: "path", foot: "private" }), way({ highway: "path", foot: "no" }),
  { type: "way", tags: { highway: "path" } }, { type: "node", geometry: [] },
] };
const ways = waysFromOverpass(overpass);
assert.equal(ways.length, 5);
assert.deepEqual(ways[0], { highway: "residential", points: [[-33.638123, 115.386123], [-33.637, 115.387]] });
assert.equal(ways[1].footway, "sidewalk");
assert.equal(ways[2].service, "driveway");
assert.equal(ways[2].access, "destination");
assert.throws(() => waysFromOverpass({ remark: "runtime error: timeout", elements: [] }));
assert.throws(() => waysFromOverpass({ elements: [way({ highway: "path" }), { ...way({ highway: "path" }), geometry: [{ lat: NaN, lon: 1 }] }] }));
assert.deepEqual(waysFromOverpass({ elements: [] }), []);

let now = 1_000_000;
const originalNow = Date.now;
Date.now = () => now;
const rows = new Map(), files = new Map(), scheduled = [], deleted = [];
let sequence = 0;
const ctx = {
  userId: "test-user",
  db: {
    query: () => ({ withIndex: (_, fn) => {
      let osmId;
      fn({ eq: (_, value) => { osmId = value; } });
      return { unique: async () => structuredClone([...rows.values()].find((row) => row.osmId === osmId) ?? null) };
    } }),
    insert: async (_, value) => { const id = `row-${++sequence}`; rows.set(id, { ...value, _id: id }); return id; },
    patch: async (_, id, patch) => { Object.assign(rows.get(id), patch); },
  },
  storage: {
    store: async (blob) => { const id = `file-${++sequence}`; files.set(id, JSON.parse(await blob.text())); return id; },
    getUrl: async (id) => files.has(id) ? `https://test.invalid/${id}` : null,
    delete: async (id) => { deleted.push(id); files.delete(id); },
  },
  scheduler: { runAfter: async (delay, fn, args) => { scheduled.push({ delay, fn, args }); } },
};
const invoke = (fn, args = {}, context = ctx) => fn._handler(context, args);
const run = async (ref, args) => invoke(places[getFunctionName(ref).split(":")[1]], args);
ctx.runQuery = run;
// Convex mutations serialize conflicting reads/writes. This queue gives the
// in-memory stand-in the same atomic boundary for concurrent action tests.
let mutations = Promise.resolve();
ctx.runMutation = (ref, args) => {
  const result = mutations.then(() => run(ref, args));
  mutations = result.catch(() => {});
  return result;
};
const originalFetch = globalThis.fetch;
let fetches = [], failFirstOverpass = false;
globalThis.fetch = async (url, options) => {
  fetches.push({ url: String(url), options });
  if (String(url).includes("nominatim")) return Response.json(nominatim);
  if (failFirstOverpass && String(url).includes("overpass-api.de")) return new Response("busy", { status: 504 });
  return Response.json(overpass);
};
try {
  await assert.rejects(invoke(places.requireUser, {}, { userId: null }), /Not signed in/);
  await assert.rejects(invoke(places.enqueue, { osmIds: [123] }, { userId: null }), /Not signed in/);
  await assert.rejects(invoke(places.get, { osmId: 123 }, { ...ctx, runQuery: (ref, args) => invoke(places.requireUser, args, { userId: null }) }), /Not signed in/);
  for (const osmId of [-1, 0, 1.5, Infinity]) await assert.rejects(invoke(places.claim, { osmId }), /Invalid OSM/);

  const first = await invoke(places.claim, { osmId: 123 });
  assert.equal(first.kind, "fetch");
  assert.equal((await invoke(places.claim, { osmId: 123 })).kind, "busy");
  await invoke(places.finish, { osmId: 123, lease: first.lease });
  failFirstOverpass = true;
  const cold = await invoke(places.get, { osmId: 123 });
  assert.equal(fetches.length, 3); // Nominatim, primary 504, fallback success.
  assert.equal(fetches[2].url, "https://maps.mail.ru/osm/tools/overpass/api/interpreter");
  assert.ok(fetches[0].options.headers["User-Agent"].startsWith("Walkies/"));
  const stored = [...files.values()][0];
  assert.deepEqual(stored, { boundary: parsed.boundary, ways });
  assert.deepEqual(await invoke(places.get, { osmId: 123 }), cold);
  assert.equal(fetches.length, 3); // Ready cache never talks to either OSM service.

  await invoke(places.warm, { osmIds: [123, 124, 125, 124] });
  assert.equal(scheduled.length, 2);
  assert.deepEqual(scheduled.map((job) => job.delay), [0, 1100]);
  await invoke(places.warm, { osmIds: [124, 125] });
  assert.equal(scheduled.length, 2);
  await assert.rejects(invoke(places.warm, { osmIds: Array(101).fill(123) }), /Too many/);
  assert.equal(await invoke(places.nominatimSlot), 1100);
  now += 1100;
  assert.equal(await invoke(places.nominatimSlot), 0);
  assert.equal(await invoke(places.nominatimSlot), 1100);

  const oldFile = [...rows.values()].find((row) => row.osmId === 123).file;
  now += 60 * 24 * 3600 * 1000 + 1;
  const expired = await invoke(places.claim, { osmId: 123 });
  assert.equal(expired.kind, "fetch");
  now += 6 * 60 * 1000 + 1;
  const replacement = await invoke(places.claim, { osmId: 123 });
  assert.equal(replacement.kind, "fetch");
  files.set("orphan", {});
  assert.equal(await invoke(places.finish, { osmId: 123, lease: expired.lease, file: "orphan" }), false);
  assert.ok(deleted.includes("orphan"));
  assert.equal((await invoke(places.claim, { osmId: 123 })).kind, "busy");
  await invoke(places.finish, { osmId: 123, lease: replacement.lease });
  assert.ok(files.has(oldFile)); // Failed refresh retains last successful file.
  failFirstOverpass = false;
  await invoke(places.get, { osmId: 123 });
  assert.ok(deleted.includes(oldFile));
  // Concurrent cold callers share one upstream fetch, including the waiting caller.
  now += 60 * 24 * 3600 * 1000 + 1;
  const beforeConcurrent = fetches.length;
  const concurrent = await Promise.all([invoke(places.get, { osmId: 123 }), invoke(places.get, { osmId: 123 })]);
  assert.deepEqual(concurrent[0], concurrent[1]);
  assert.equal(fetches.length - beforeConcurrent, 2);

  // A delayed warm job whose lease was superseded must not hit upstream services.
  const beforeDelayedJob = fetches.length;
  await invoke(places.fetchOwned, { osmId: 124, lease: scheduled[0].args.lease });
  assert.equal(fetches.length, beforeDelayedJob);
  console.log("Place shaping, auth, cache hits, TTL, duplicate claims, warm scheduling, throttle, fallback and lease cleanup passed.");
} finally {
  Date.now = originalNow;
  globalThis.fetch = originalFetch;
}

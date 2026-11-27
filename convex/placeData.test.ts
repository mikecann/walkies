import { expect, test } from "vitest";
import {
  isWalkable, readBoundaryFromStream, readCitySummaryFromStream, speedLimit, streamPlaceData, streamPlaceWays, waysFromOverpass,
  type PlaceData,
} from "./placeData";

// Sample OSM ways, by their tags. Keep in step with WalkableRuleTests.swift and WalkableRuleTest.kt.
const walkable: Record<string, string>[] = [
  { highway: "residential" },
  { highway: "footway" },
  { highway: "footway", footway: "sidewalk" },
  { highway: "cycleway", maxspeed: "80" },
  { highway: "secondary", maxspeed: "60" },
  { highway: "primary", sidewalk: "both" },
  { highway: "primary", sidewalk: "left" },
  { highway: "trunk", sidewalk: "separate" },
  { highway: "trunk_link", "sidewalk:left": "yes" },
  { highway: "primary_link", "sidewalk:both": "separate" },
  { highway: "trunk", foot: "designated" },
  { highway: "primary", foot: "permissive" },
  { highway: "primary", footway: "sidewalk" },
  { highway: "trunk", foot: "yes", maxspeed: "100" },
  { highway: "secondary", maxspeed: "90", sidewalk: "right" },
  { highway: "tertiary", maxspeed: "40 mph" },
  { highway: "unclassified", maxspeed: "AU:rural" },
];
const unwalkable: Record<string, string>[] = [
  { highway: "motorway" },
  { highway: "motorway_link", sidewalk: "both" },
  { highway: "trunk" },
  { highway: "trunk_link" },
  { highway: "primary" },
  { highway: "primary_link" },
  { highway: "primary", sidewalk: "no" },
  { highway: "trunk", sidewalk: "none", "sidewalk:left": "no" },
  { highway: "secondary", maxspeed: "80" },
  { highway: "tertiary", maxspeed: "100 km/h" },
  { highway: "unclassified", maxspeed: "50 mph" },
  { highway: "secondary", maxspeed: "80", foot: "permissive" },
  { highway: "residential", access: "private" },
  { highway: "service", foot: "no" },
  { highway: "construction" },
];

test("busy roads only count as walkable with a footpath or an open invitation", () => {
  for (const tags of walkable) expect([tags, isWalkable(tags)]).toEqual([tags, true]);
  for (const tags of unwalkable) expect([tags, isWalkable(tags)]).toEqual([tags, false]);
  expect(isWalkable({})).toBe(false);
});

test("speed limits read km/h, mph and leave out the rest", () => {
  expect(speedLimit("80")).toBe(80);
  expect(speedLimit("80 km/h")).toBe(80);
  expect(speedLimit(" 70kmh")).toBe(70);
  expect(speedLimit("50 mph")).toBeCloseTo(80.47, 2);
  expect(speedLimit("none")).toBeNull();
  expect(speedLimit("AU:urban")).toBeNull();
  expect(speedLimit(undefined)).toBeNull();
});

test("the street cache leaves out unwalkable roads and keeps the stored format", () => {
  const way = (id: number, tags: Record<string, string>) => ({ type: "way", id, tags, geometry: [{ lat: -33.65, lon: 115.33 }, { lat: -33.651, lon: 115.331 }] });
  const ways = waysFromOverpass({
    elements: [
      way(1, { highway: "trunk", name: "Bussell Highway", maxspeed: "70" }),
      way(2, { highway: "footway", footway: "sidewalk", name: "Bussell Highway path" }),
      way(3, { highway: "primary", sidewalk: "both", maxspeed: "60" }),
      way(4, { highway: "secondary", maxspeed: "90" }),
      way(5, { highway: "residential", service: "x", foot: "yes" }),
    ],
  });
  expect(ways).toEqual([
    { highway: "footway", footway: "sidewalk", points: [[-33.65, 115.33], [-33.651, 115.331]] },
    { highway: "primary", points: [[-33.65, 115.33], [-33.651, 115.331]] },
    { highway: "residential", service: "x", foot: "yes", points: [[-33.65, 115.33], [-33.651, 115.331]] },
  ]);
});

function chunkedStream(text: string, chunkBytes: number): ReadableStream<Uint8Array> {
  const bytes = new TextEncoder().encode(text);
  let offset = 0;
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) { controller.close(); return; }
      controller.enqueue(bytes.subarray(offset, offset + chunkBytes));
      offset += chunkBytes;
    },
  });
}

test("readBoundaryFromStream stops and cancels before reading ways", async () => {
  const outline = [[[[115, -33], [115.01, -33], [115.01, -33.01], [115, -33]]]];
  const head = new TextEncoder().encode(`{"boundary":${JSON.stringify(outline)},"ways":[`);
  const filler = new TextEncoder().encode(`{"highway":"residential","points":[[-33.005,115.005],[-33.006,115.006]]},`);
  let pulls = 0;
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      pulls++;
      controller.enqueue(pulls === 1 ? head : filler);
    },
    cancel() { cancelled = true; },
  });
  expect(await readBoundaryFromStream(stream)).toEqual(outline);
  expect(cancelled).toBe(true);
  // Cancelled right after the boundary chunk — never streamed the endless ways array.
  expect(pulls).toBeLessThanOrEqual(2);
});

test("streamPlaceData handles tiny chunks, escaped strings, whitespace and reversed key order", async () => {
  const outline = [[[[115, -33], [115.01, -33], [115.01, -33.01], [115, -33]]]];
  const ways: PlaceData["ways"] = [
    { highway: "residential", service: "café \"a}b[c]\" \\", points: [[-33.001, 115.001], [-33.002, 115.002]] },
    { highway: "footway", footway: "sidewalk", points: [[-33.003, 115.003], [-33.004, 115.004]] },
  ];
  // 3-byte chunks split multi-byte UTF-8 ("é") and escape sequences across boundaries.
  const pretty = JSON.stringify({ boundary: outline, ways }, null, 2);
  let gotBoundary: PlaceData["boundary"] | undefined;
  const gotWays: PlaceData["ways"] = [];
  const first = await streamPlaceData(
    chunkedStream(pretty, 3),
    (b) => { gotBoundary = b; },
    (w) => { gotWays.push(w); },
  );
  expect(first).toEqual({ sawBoundary: true, waysSkipped: false });
  expect(gotBoundary).toEqual(outline);
  expect(gotWays).toEqual(ways);

  // Reversed key order (`ways` before `boundary`): skips ways on pass 1, streams on pass 2.
  const reversed = JSON.stringify({ ways, boundary: outline });
  const pass2Ways: PlaceData["ways"] = [];
  const pass1 = await streamPlaceData(chunkedStream(reversed, 5), (b) => { gotBoundary = b; }, (w) => { pass2Ways.push(w); });
  expect(pass1).toEqual({ sawBoundary: true, waysSkipped: true });
  expect(pass2Ways).toEqual([]);
  await streamPlaceWays(chunkedStream(reversed, 5), (w) => { pass2Ways.push(w); });
  expect(pass2Ways).toEqual(ways);
});

test("readCitySummaryFromStream extracts osmId, name and walked tiles while skipping roads and rejecting broken JSON", async () => {
  const city = {
    id: "P",
    name: "Birmingham — Central",
    detail: "Birmingham, England, United Kingdom",
    osmId: 162378,
    visited: [[0, 0], [1, 0], [2, 1], [3, 2]],
    roads: Array.from({ length: 200 }, (_, i) => ({ pts: [[52.48 + i * 0.0001, -1.89], [52.48, -1.9]] })),
    tiles: Array.from({ length: 200 }, (_, i) => [i, i]),
  };
  expect(await readCitySummaryFromStream(chunkedStream(JSON.stringify(city), 7))).toEqual({
    osmId: 162378,
    name: "Birmingham — Central",
    walkedTiles: 4,
  });
  expect(await readCitySummaryFromStream(chunkedStream(JSON.stringify({ name: "No ID", visited: null, osmId: -5 }), 4))).toEqual({
    osmId: null,
    name: "No ID",
    walkedTiles: 0,
  });
  await expect(readCitySummaryFromStream(chunkedStream("{broken", 3))).rejects.toThrow(SyntaxError);
  await expect(readCitySummaryFromStream(chunkedStream("{\"osmId\": 42", 4))).rejects.toThrow(SyntaxError);
  await expect(readCitySummaryFromStream(chunkedStream("[]", 2))).rejects.toThrow(SyntaxError);
});

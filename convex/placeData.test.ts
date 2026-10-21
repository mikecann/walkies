import { expect, test } from "vitest";
import { isWalkable, speedLimit, waysFromOverpass } from "./placeData";

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

import { expect, test } from "vitest";
import { centre, corners, hexAt, hexContaining, hexes, neighbours, project, roundHex, unproject } from "./grid";

// Also hard-coded in HexGridTests.swift and design/grid.md. No runtime code generates these expectations.
const examples = [
  [0, 0, 0, 0],
  [-33.65, 115.35, 145525, -44196],
  [-33.638, 115.386, 145554, -44178],
  [51.5074, -0.1278, -37383, 74493],
  [0, 30, 32101, 0],
  [-33.65, -115.35, -101329, -44196],
  [40.7128, -74.006, -106770, 55164],
  [85, 179.9, 81661, 221671],
  [-85, -179.9, -81661, -221671],
];

test.each(examples)("world tile at (%s, %s) is (%s, %s)", (lat, lon, q, r) => {
  const coordinate = { lat, lon }, hex = { q, r };
  expect(hexContaining(coordinate)).toEqual(hex);
  expect(hexContaining(unproject(centre(hex)))).toEqual(hex);
  const roundTrip = unproject(project(coordinate));
  expect(roundTrip.lat).toBeCloseTo(lat, 9);
  expect(roundTrip.lon).toBeCloseTo(lon, 9);
});

test("rounding uses Swift's negative half ties and cube-error priority", () => {
  expect(roundHex(0.5, 0)).toEqual({ q: 1, r: 0 });
  expect(roundHex(-0.5, 0)).toEqual({ q: -1, r: 0 });
  expect(roundHex(0.5, 0.5)).toEqual({ q: 1, r: 0 });
  expect(roundHex(-0.5, -0.5)).toEqual({ q: -1, r: 0 });
  expect(roundHex(0.4, 0.4)).toEqual({ q: 0, r: 1 });
});

test("neighbours, corner order and inclusive centre bounds", () => {
  expect(neighbours({ q: 0, r: 0 })).toEqual([
    { q: 1, r: 0 }, { q: 1, r: -1 }, { q: 0, r: -1 },
    { q: -1, r: 0 }, { q: -1, r: 1 }, { q: 0, r: 1 },
  ]);
  const h = hexContaining({ lat: -33.65, lon: 115.35 }), c = centre(h);
  expect(hexAt(c)).toEqual(h);
  expect(hexes(c, c)).toEqual([h]);
  corners(h).map(project).forEach((p, i) => {
    expect(Math.hypot(p.x - c.x, p.y - c.y)).toBeCloseTo(50, 6);
    const angle = (60 * i - 30) * Math.PI / 180;
    expect(p.x - c.x).toBeCloseTo(50 * Math.cos(angle), 6);
    expect(p.y - c.y).toBeCloseTo(50 * Math.sin(angle), 6);
  });
});

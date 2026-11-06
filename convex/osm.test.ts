import { expect, test } from "vitest";
import { quarters, readCapped, TooBig, TooManyStreets, waysInTiles, type Box } from "./osm";

const way = (id: number, lat: number) => ({ type: "way", id, tags: { highway: "residential" }, geometry: [{ lat, lon: 115 }, { lat: lat + 0.001, lon: 115.001 }] });
const whole: Box = { south: -34, west: 115, north: -33, east: 116 };

test("a box is split into four that cover it", () => {
  expect(quarters(whole)).toEqual([
    { south: -33.5, west: 115, north: -33, east: 115.5 }, { south: -33.5, west: 115.5, north: -33, east: 116 },
    { south: -34, west: 115, north: -33.5, east: 115.5 }, { south: -34, west: 115.5, north: -33.5, east: 116 },
  ]);
});

test("a way that comes back from two tiles is kept once, by its id", async () => {
  const ways = await waysInTiles(whole, async (box: Box) => {
    if (box === whole) throw new TooBig("too much");
    // Same way, but each tile's copy differs, so only the id says they're one way.
    return { elements: [{ ...way(7, -33.5), tags: { highway: "residential", foot: box.west === 115 ? "yes" : "designated" } }] };
  }, 3);
  expect(ways).toHaveLength(1);
});

test("a box Overpass can't answer in one go is fetched in quarters, without doubling ways that cross them", async () => {
  const asked: Box[] = [];
  const ways = await waysInTiles(whole, async (box: Box) => {
    asked.push(box);
    if (box === whole) throw new TooBig("too much");
    // Way 1 crosses every quarter, so every quarter returns it. The other is the quarter's own.
    return { elements: [way(1, -33.25), way(asked.length + 10, box.south + (box.west - 115) / 10)] };
  }, 3);
  expect(asked).toHaveLength(5);
  const starts = ways.map((w) => JSON.parse(w).points[0]);
  expect(starts).toHaveLength(5);
  expect(starts.filter(([lat]) => lat === -33.25)).toHaveLength(1);
  expect(new Set(ways).size).toBe(5);
});

test("it gives up once the tiles are as small as they go", async () => {
  let asked = 0;
  await expect(waysInTiles(whole, async () => { asked++; throw new TooBig("too much"); }, 2)).rejects.toBeInstanceOf(TooBig);
  // Stops at the first tile that's still too big at the smallest size, rather than asking Overpass for the rest.
  expect(asked).toBe(3);
});

test("any other failure isn't split, it fails the fetch", async () => {
  let asked = 0;
  await expect(waysInTiles(whole, async () => { asked++; throw new Error("OSM returned 500"); }, 3)).rejects.toThrow("500");
  expect(asked).toBe(1);
});

test("a response over the size cap is cut off rather than read into memory", async () => {
  const big = new Response(new ReadableStream({
    start(controller) { for (let i = 0; i < 10; i++) controller.enqueue(new Uint8Array(1000)); controller.close(); },
  }));
  await expect(readCapped(big, 5000)).rejects.toBeInstanceOf(TooBig);
  expect(await readCapped(new Response('{"ok":true}'), 5000)).toBe('{"ok":true}');
});

test("a place with more streets than the file can hold fails rather than filling memory", async () => {
  const many = { elements: Array.from({ length: 50 }, (_, i) => way(i, -33.5)) };
  await expect(waysInTiles(whole, async () => many, 3, 2000)).rejects.toBeInstanceOf(TooManyStreets);
  expect(await waysInTiles(whole, async () => many, 3)).toHaveLength(50);
});

test("the fetcher is told when a box is as small as it goes", async () => {
  const smallest: boolean[] = [];
  await expect(waysInTiles(whole, async (_, last) => { smallest.push(last); throw new TooBig("too much"); }, 1)).rejects.toBeInstanceOf(TooBig);
  expect(smallest).toEqual([false, true]);
});

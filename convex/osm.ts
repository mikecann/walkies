// Fetching from OpenStreetMap, shared by places.ts and the Node action in
// placeStreets.ts. Plain code with no Convex functions, so both runtimes can import it.
import { walkableElements } from "./placeData";

export const userAgent = "Walkies/0.1 (iOS walking app; https://github.com/mikecann/walkies)";
export const overpassEndpoints = [
  "https://overpass-api.de/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];

/** OSM answered with an HTTP error. */
export class OsmError extends Error {
  constructor(readonly status: number) { super(`OSM returned ${status}`); }
}

/** The answer is too big to take in one go: more than the size cap, or more than
 * Overpass could do before its gateway gave up. Fetching it in smaller pieces works. */
export class TooBig extends Error {}

/** A response's body as text, giving up once it passes `cap` bytes, so a huge one
 * never ends up in memory. */
export async function readCapped(response: Response, cap: number): Promise<string> {
  if (!response.body) return await response.text();
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const parts: string[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > cap) {
      await reader.cancel();
      throw new TooBig(`More than ${Math.round(cap / 1024 / 1024)} MB`);
    }
    parts.push(decoder.decode(value, { stream: true }));
  }
  parts.push(decoder.decode());
  return parts.join("");
}

export async function fetchJSON(url: string, timeout: number, init?: RequestInit, cap = Infinity): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(url, { ...init, headers: { "User-Agent": userAgent, "Accept-Language": "en", ...init?.headers }, signal: controller.signal });
    if (!response.ok) throw new OsmError(response.status);
    return cap === Infinity ? await response.json() : JSON.parse(await readCapped(response, cap));
  } finally {
    clearTimeout(timer);
  }
}

export type Box = { south: number; west: number; north: number; east: number };

export function quarters({ south, west, north, east }: Box): Box[] {
  const midLat = (south + north) / 2, midLon = (west + east) / 2;
  return [
    { south: midLat, west, north, east: midLon }, { south: midLat, west: midLon, north, east },
    { south, west, north: midLat, east: midLon }, { south, west: midLon, north: midLat, east },
  ];
}

/** The walkable ways in `box`, each as its JSON, from Overpass answers `fetchBox` gets.
 * A box it can't answer in one go (TooBig) is split into quarters, up to `maxDepth`
 * times. A way that crosses tiles comes back from each, with its whole geometry, so
 * it's kept once by its id. Only one tile's answer is parsed at a time, and the ways
 * are kept as JSON, so memory is about the size of the file being written. */
export async function waysInTiles(box: Box, fetchBox: (box: Box) => Promise<unknown>, maxDepth: number): Promise<string[]> {
  const seen = new Set<number>();
  const ways: string[] = [];
  async function visit(tile: Box, depth: number) {
    let answer: unknown;
    try {
      answer = await fetchBox(tile);
    } catch (error) {
      if (!(error instanceof TooBig) || depth >= maxDepth) throw error;
      for (const quarter of quarters(tile)) await visit(quarter, depth + 1);
      return;
    }
    for (const { id, way } of walkableElements(answer)) {
      if (Number.isFinite(id)) {
        if (seen.has(id)) continue;
        seen.add(id);
      }
      ways.push(JSON.stringify(way));
    }
  }
  await visit(box, 0);
  return ways;
}

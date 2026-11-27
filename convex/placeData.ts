/** The storage format shared with CachedPlaceData on the phone. */
export type PlaceData = {
  // GeoJSON MultiPolygon order: polygons, rings (outer then holes), [lon, lat].
  boundary: number[][][][];
  ways: {
    highway: string;
    footway?: string;
    service?: string;
    access?: string;
    foot?: string;
    points: number[][]; // [lat, lon], matching the phone's coordinates.
  }[];
};

const excluded = "motorway|motorway_link|construction|proposed|raceway|bus_guideway|abandoned|razed";
const excludedHighways = new Set(excluded.split("|"));
// Busy roads only count when OSM says you can walk along them.
const busyRoads = new Set(["trunk", "trunk_link", "primary", "primary_link"]);
const pathTypes = new Set(["footway", "path", "cycleway", "pedestrian", "steps", "bridleway", "corridor"]);
const sidewalkValues = new Set(["both", "left", "right", "yes", "separate"]);

/** km/h from an OSM maxspeed ("80", "80 km/h", "50 mph"), or null for "none", "AU:urban" and the like. */
export function speedLimit(maxspeed: string | undefined): number | null {
  const match = maxspeed?.trim().match(/^(\d+(?:\.\d+)?)\s*(km\/h|kmh|kph|mph)?$/i);
  if (!match) return null;
  const value = Number(match[1]);
  return match[2]?.toLowerCase() === "mph" ? value * 1.609344 : value;
}

/** Keep this in step with WalkableRule in OSMClient.swift and OSMClient.kt.
 * Motorways and private ways are out. Trunk and primary roads, and anything signed
 * 80 km/h or more, are out unless they have a footpath or are open to walkers.
 * Footpaths mapped alongside them are separate ways and stay in as normal.
 */
export function isWalkable(tags: Record<string, unknown>): boolean {
  const tag = (key: string) => typeof tags[key] === "string" ? tags[key] as string : undefined;
  const highway = tag("highway");
  if (highway === undefined || excludedHighways.has(highway)) return false;
  if (["private", "no"].includes(tag("access") ?? "") || ["private", "no"].includes(tag("foot") ?? "")) return false;
  const sidewalk = sidewalkValues.has(tag("sidewalk") ?? "")
    || ["sidewalk:left", "sidewalk:right", "sidewalk:both"].some((key) => ["yes", "separate"].includes(tag(key) ?? ""));
  const foot = tag("foot");
  const walkersWelcome = foot === "yes" || foot === "designated";
  if (busyRoads.has(highway) && !sidewalk && !walkersWelcome && foot !== "permissive" && tag("footway") !== "sidewalk") return false;
  const limit = speedLimit(tag("maxspeed"));
  if (!pathTypes.has(highway) && limit !== null && limit >= 80 && !sidewalk && !walkersWelcome) return false;
  return true;
}
const round = (n: number) => Math.round(n * 1_000_000) / 1_000_000;

function object(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid OSM object");
  return value as Record<string, unknown>;
}

function coordinate(value: unknown, limit: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || Math.abs(value) > limit) {
    throw new Error("Invalid OSM coordinate");
  }
  return round(value);
}

export function boundaryFromNominatim(value: unknown, osmId: number): { name: string; boundary: PlaceData["boundary"] } {
  if (!Array.isArray(value)) throw new Error("Invalid Nominatim response");
  const item = value.map(object).find((item) => item.osm_type === "relation" && item.osm_id === osmId);
  if (!item) throw new Error("No boundary for this relation");
  const geometry = object(item.geojson);
  const polygons = geometry.type === "Polygon" ? [geometry.coordinates]
    : geometry.type === "MultiPolygon" ? geometry.coordinates : null;
  if (!Array.isArray(polygons) || polygons.length === 0) throw new Error("Missing polygon boundary");
  const boundary = polygons.map((polygon) => {
    if (!Array.isArray(polygon) || polygon.length === 0) throw new Error("Missing polygon rings");
    return polygon.map((ring) => {
      if (!Array.isArray(ring) || ring.length < 4) throw new Error("Invalid polygon ring");
      return ring.map((point) => {
        if (!Array.isArray(point) || point.length < 2) throw new Error("Invalid polygon point");
        return [coordinate(point[0], 180), coordinate(point[1], 90)];
      });
    });
  });
  const name = typeof item.name === "string" && item.name ? item.name
    : typeof item.display_name === "string" ? item.display_name.split(",")[0] : "Somewhere";
  return { name, boundary };
}

export function boundaryBox(boundary: PlaceData["boundary"]): { south: number; west: number; north: number; east: number } {
  const outer = boundary.flatMap((polygon) => polygon[0]);
  return {
    south: Math.min(...outer.map((p) => p[1])), west: Math.min(...outer.map((p) => p[0])),
    north: Math.max(...outer.map((p) => p[1])), east: Math.max(...outer.map((p) => p[0])),
  };
}

export function walkableQuery(boundary: PlaceData["boundary"]): string {
  return walkableBoxQuery(boundaryBox(boundary));
}

/** The query for one box. The server splits a big suburb's box into tiles
 * (waysInTiles in osm.ts), which together return the same ways as the whole box. */
export function walkableBoxQuery({ south, west, north, east }: { south: number; west: number; north: number; east: number }): string {
  // Keep this query in step with OSMClient.walkableWays. `out geom` brings every
  // tag, which isWalkable needs (sidewalk, foot, maxspeed) before the ways are stored.
  return `[out:json][timeout:120];
way["highway"]["highway"!~"^(${excluded})$"]["access"!~"^(private|no)$"]["foot"!~"^(private|no)$"](${south},${west},${north},${east});
out geom;`;
}

export function waysFromOverpass(value: unknown): PlaceData["ways"] {
  return Array.from(walkableElements(value), (element) => element.way);
}

/** Throws unless `value` looks like a complete Overpass answer. Overpass can return
 * HTTP 200 with a timeout remark and incomplete elements. */
export function checkOverpassAnswer(value: unknown): { elements: unknown[] } {
  const response = object(value);
  if (response.remark || !Array.isArray(response.elements)) throw new Error("Incomplete Overpass response");
  return response as { elements: unknown[] };
}

/** The walkable ways in an Overpass answer, with their OSM ids, one at a time, so a
 * caller can write each out before the next is built. */
export function* walkableElements(value: unknown): Generator<{ id: number; way: PlaceData["ways"][number] }> {
  for (const item of checkOverpassAnswer(value).elements) {
    const element = object(item);
    if (element.type !== "way" || !Array.isArray(element.geometry)) continue;
    const tags = object(element.tags ?? {});
    if (!isWalkable(tags)) continue;
    const way: PlaceData["ways"][number] = {
      highway: tags.highway as string,
      points: element.geometry.map((value) => {
        const point = object(value);
        return [coordinate(point.lat, 90), coordinate(point.lon, 180)];
      }),
    };
    for (const key of ["footway", "service", "access", "foot"] as const) {
      if (typeof tags[key] === "string") way[key] = tags[key];
    }
    yield { id: typeof element.id === "number" ? element.id : Number.NaN, way };
  }
}

type ArrayMode = "items" | "count";
type KeyAction = "capture" | ArrayMode | "skip";

type ObjectHandlers = {
  onKey: (key: string) => KeyAction;
  onValue?: (key: string, json: string) => boolean | void;
  onItem?: (key: string, json: string) => boolean | void;
  onCount?: (key: string, count: number) => boolean | void;
};

const isSpace = (code: number) => code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d;
const isPrimitiveStart = (code: number) =>
  code === 0x2d || (code >= 0x30 && code <= 0x39) || code === 0x74 || code === 0x66 || code === 0x6e;

/**
 * Streams a top-level JSON object from `stream`, capturing only the fields the caller
 * asks for, iterating or counting elements of chosen arrays one by one, and skipping
 * everything else without buffering it. Returning `false` from a callback stops and
 * cancels the stream immediately.
 */
export async function scanJsonObject(stream: ReadableStream<Uint8Array>, handlers: ObjectHandlers): Promise<void> {
  type Phase =
    | "start" | "firstKey" | "nextKey" | "inKey" | "colon" | "valueStart" | "afterValue"
    | "inContainer" | "inStringValue" | "inPrimitive"
    | "arrayFirst" | "arrayNext" | "arrayAfterItem"
    | "arrayItemContainer" | "arrayItemString" | "arrayItemPrimitive"
    | "done";
  const reader = stream.getReader();
  const decoder = new TextDecoder("utf-8");
  let phase: Phase = "start";
  let currentKey = "";
  let capture = false;
  let arrayMode: ArrayMode = "items";
  let arrayCount = 0;
  let depth = 0;
  let inString = false;
  let escaped = false;
  let captureStart = -1;
  let captureParts: string[] = [];
  let stopped = false;

  const finishCapture = (chunk: string, end: number): string => {
    const tail = chunk.slice(captureStart, end);
    const text = captureParts.length === 0 ? tail : (captureParts.push(tail), captureParts.join(""));
    captureParts = [];
    captureStart = -1;
    return text;
  };
  const beginCapture = (index: number) => {
    captureParts = [];
    captureStart = index;
  };
  const unexpected = (ch: string) => new SyntaxError(`Unexpected character ${JSON.stringify(ch)} in JSON`);

  const processChunk = (chunk: string) => {
    for (let i = 0; i < chunk.length && !stopped; i++) {
      const code = chunk.charCodeAt(i);
      const ch = chunk[i]!;
      switch (phase) {
        case "start":
          if (isSpace(code)) break;
          if (ch !== "{") throw unexpected(ch);
          phase = "firstKey";
          break;
        case "firstKey":
          if (isSpace(code)) break;
          if (ch === "}") { phase = "done"; break; }
          if (ch !== "\"") throw unexpected(ch);
          escaped = false;
          beginCapture(i);
          phase = "inKey";
          break;
        case "nextKey":
          if (isSpace(code)) break;
          if (ch !== "\"") throw unexpected(ch);
          escaped = false;
          beginCapture(i);
          phase = "inKey";
          break;
        case "inKey":
          if (escaped) escaped = false;
          else if (ch === "\\") escaped = true;
          else if (ch === "\"") {
            currentKey = JSON.parse(finishCapture(chunk, i + 1)) as string;
            phase = "colon";
          }
          break;
        case "colon":
          if (isSpace(code)) break;
          if (ch !== ":") throw unexpected(ch);
          phase = "valueStart";
          break;
        case "afterValue":
          if (isSpace(code)) break;
          if (ch === ",") phase = "nextKey";
          else if (ch === "}") phase = "done";
          else throw unexpected(ch);
          break;
        case "valueStart": {
          if (isSpace(code)) break;
          const action = handlers.onKey(currentKey);
          if ((action === "items" || action === "count") && ch === "[") {
            arrayMode = action;
            arrayCount = 0;
            phase = "arrayFirst";
            break;
          }
          capture = action === "capture";
          if (ch === "{" || ch === "[") {
            depth = 1; inString = false; escaped = false;
            if (capture) beginCapture(i);
            phase = "inContainer";
          } else if (ch === "\"") {
            escaped = false;
            if (capture) beginCapture(i);
            phase = "inStringValue";
          } else if (isPrimitiveStart(code)) {
            if (capture) beginCapture(i);
            phase = "inPrimitive";
          } else {
            throw unexpected(ch);
          }
          break;
        }
        case "inContainer":
          if (inString) {
            if (escaped) escaped = false;
            else if (ch === "\\") escaped = true;
            else if (ch === "\"") inString = false;
          } else if (ch === "\"") {
            inString = true;
          } else if (ch === "{" || ch === "[") {
            depth++;
          } else if (ch === "}" || ch === "]") {
            depth--;
            if (depth === 0) {
              if (capture && handlers.onValue?.(currentKey, finishCapture(chunk, i + 1)) === false) stopped = true;
              phase = "afterValue";
            }
          }
          break;
        case "inStringValue":
          if (escaped) escaped = false;
          else if (ch === "\\") escaped = true;
          else if (ch === "\"") {
            if (capture && handlers.onValue?.(currentKey, finishCapture(chunk, i + 1)) === false) stopped = true;
            phase = "afterValue";
          }
          break;
        case "inPrimitive":
          if (isSpace(code) || ch === "," || ch === "}") {
            if (capture && handlers.onValue?.(currentKey, finishCapture(chunk, i)) === false) stopped = true;
            phase = "afterValue";
            i--;
          }
          break;
        case "arrayFirst":
          if (isSpace(code)) break;
          if (ch === "]") {
            if (arrayMode === "count" && handlers.onCount?.(currentKey, 0) === false) stopped = true;
            phase = "afterValue";
            break;
          }
          phase = "arrayNext";
          i--;
          break;
        case "arrayNext":
          if (isSpace(code)) break;
          capture = arrayMode === "items";
          if (ch === "{" || ch === "[") {
            depth = 1; inString = false; escaped = false;
            if (capture) beginCapture(i);
            phase = "arrayItemContainer";
          } else if (ch === "\"") {
            escaped = false;
            if (capture) beginCapture(i);
            phase = "arrayItemString";
          } else if (isPrimitiveStart(code)) {
            if (capture) beginCapture(i);
            phase = "arrayItemPrimitive";
          } else {
            throw unexpected(ch);
          }
          break;
        case "arrayAfterItem":
          if (isSpace(code)) break;
          if (ch === ",") phase = "arrayNext";
          else if (ch === "]") {
            if (arrayMode === "count" && handlers.onCount?.(currentKey, arrayCount) === false) stopped = true;
            phase = "afterValue";
          } else {
            throw unexpected(ch);
          }
          break;
        case "arrayItemContainer":
          if (inString) {
            if (escaped) escaped = false;
            else if (ch === "\\") escaped = true;
            else if (ch === "\"") inString = false;
          } else if (ch === "\"") {
            inString = true;
          } else if (ch === "{" || ch === "[") {
            depth++;
          } else if (ch === "}" || ch === "]") {
            depth--;
            if (depth === 0) {
              arrayCount++;
              if (capture && handlers.onItem?.(currentKey, finishCapture(chunk, i + 1)) === false) stopped = true;
              phase = "arrayAfterItem";
            }
          }
          break;
        case "arrayItemString":
          if (escaped) escaped = false;
          else if (ch === "\\") escaped = true;
          else if (ch === "\"") {
            arrayCount++;
            if (capture && handlers.onItem?.(currentKey, finishCapture(chunk, i + 1)) === false) stopped = true;
            phase = "arrayAfterItem";
          }
          break;
        case "arrayItemPrimitive":
          if (isSpace(code) || ch === "," || ch === "]") {
            arrayCount++;
            if (capture && handlers.onItem?.(currentKey, finishCapture(chunk, i)) === false) stopped = true;
            phase = "arrayAfterItem";
            i--;
          }
          break;
        case "done":
          if (!isSpace(code)) throw unexpected(ch);
          break;
      }
    }
    if (!stopped && captureStart >= 0) {
      captureParts.push(chunk.slice(captureStart));
      captureStart = 0;
    }
  };

  try {
    while (!stopped) {
      const { done, value } = await reader.read();
      if (done) break;
      processChunk(decoder.decode(value, { stream: true }));
    }
    if (!stopped) {
      const tail = decoder.decode();
      if (tail) processChunk(tail);
      if ((phase as Phase) !== "done") throw new SyntaxError("Unexpected end of JSON input");
    }
  } finally {
    await reader.cancel().catch(() => undefined);
  }
}

/** Reads only `boundary` from a cached PlaceData JSON stream, cancelling before `ways`. */
export async function readBoundaryFromStream(stream: ReadableStream<Uint8Array>): Promise<PlaceData["boundary"]> {
  let boundary: PlaceData["boundary"] | undefined;
  await scanJsonObject(stream, {
    onKey: (key) => key === "boundary" ? "capture" : "skip",
    onValue: (_key, json) => {
      boundary = JSON.parse(json) as PlaceData["boundary"];
      return false;
    },
  });
  if (!Array.isArray(boundary) || boundary.length === 0) throw new Error("Place data has no boundary");
  return boundary;
}

/**
 * Streams a cached PlaceData file: calls `onBoundary` once the outline is read (return
 * `false` to skip the streets), then `onWay` for each street one at a time. Reports
 * `waysSkipped` if a non-standard file put `ways` before `boundary` so the caller can
 * make a second pass over `ways`.
 */
export async function streamPlaceData(
  stream: ReadableStream<Uint8Array>,
  onBoundary: (boundary: PlaceData["boundary"]) => boolean | void,
  onWay: (way: PlaceData["ways"][number]) => void,
): Promise<{ sawBoundary: boolean; waysSkipped: boolean }> {
  let sawBoundary = false;
  let waysSkipped = false;
  await scanJsonObject(stream, {
    onKey: (key) => {
      if (key === "boundary") return "capture";
      if (key === "ways") {
        if (!sawBoundary) { waysSkipped = true; return "skip"; }
        return "items";
      }
      return "skip";
    },
    onValue: (_key, json) => {
      const boundary = JSON.parse(json) as PlaceData["boundary"];
      if (!Array.isArray(boundary) || boundary.length === 0) throw new Error("Place data has no boundary");
      sawBoundary = true;
      return onBoundary(boundary);
    },
    onItem: (_key, json) => {
      onWay(JSON.parse(json) as PlaceData["ways"][number]);
    },
  });
  return { sawBoundary, waysSkipped };
}

/** Streams only `ways` from a cached PlaceData file, one way at a time. */
export async function streamPlaceWays(
  stream: ReadableStream<Uint8Array>,
  onWay: (way: PlaceData["ways"][number]) => void,
): Promise<void> {
  await scanJsonObject(stream, {
    onKey: (key) => key === "ways" ? "items" : "skip",
    onItem: (_key, json) => {
      onWay(JSON.parse(json) as PlaceData["ways"][number]);
    },
  });
}

/** Reads a saved phone City file's relation id, name and walked-tile count without loading its roads or tiles. */
export async function readCitySummaryFromStream(
  stream: ReadableStream<Uint8Array>,
): Promise<{ osmId: number | null; name: string; walkedTiles: number }> {
  let osmId: number | null = null;
  let name = "";
  let walkedTiles = 0;
  await scanJsonObject(stream, {
    onKey: (key) => key === "osmId" || key === "name" ? "capture" : key === "visited" ? "count" : "skip",
    onValue: (key, json) => {
      const value: unknown = JSON.parse(json);
      if (key === "osmId" && typeof value === "number" && Number.isSafeInteger(value) && value > 0) osmId = value;
      if (key === "name" && typeof value === "string") name = value;
    },
    onCount: (_key, count) => { walkedTiles = count; },
  });
  return { osmId, name, walkedTiles };
}

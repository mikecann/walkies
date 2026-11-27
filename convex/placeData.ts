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

type ArrayMode = "none" | "items" | "count";
type KeyAction = "capture" | { capture: number } | "items" | "count" | "skip";

type ObjectHandlers = {
  onKey: (key: string, firstChar: string) => KeyAction;
  onValue?: (key: string, json: string) => boolean | void;
  onItem?: (key: string, json: string) => boolean | void;
  onCount?: (key: string, count: number) => boolean | void;
  maxKeyChars?: number;
  maxCaptureChars?: number;
  maxDepth?: number;
};

const defaultMaxKeyChars = 16 * 1024;
const defaultMaxCaptureChars = 64 * 1024 * 1024;
const defaultMaxDepth = 512;
const cityOsmIdMaxChars = 64;
const cityNameMaxChars = 4096;

const isSpace = (code: number) => code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d;
const isDigit = (code: number) => code >= 0x30 && code <= 0x39;
const isHex = (code: number) =>
  (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x46) || (code >= 0x61 && code <= 0x66);
const isValueStart = (code: number) =>
  code === 0x7b || code === 0x5b || code === 0x22 || code === 0x2d || isDigit(code)
  || code === 0x74 || code === 0x66 || code === 0x6e;
const isNumberStart = (ch: string) => ch === "-" || (ch >= "0" && ch <= "9");

const CONTAINER_OBJ = 1;
const CONTAINER_ARR = 2;

const ST_ROOT = 0;
const ST_OBJ_FIRST = 1;
const ST_OBJ_KEY = 2;
const ST_OBJ_COLON = 3;
const ST_VALUE = 4;
const ST_OBJ_AFTER = 5;
const ST_ARR_FIRST = 6;
const ST_ARR_AFTER = 7;
const ST_STRING = 8;
const ST_NUMBER = 9;
const ST_LITERAL = 10;
const ST_DONE = 11;

const NUM_SIGN = 0;
const NUM_ZERO = 1;
const NUM_INT = 2;
const NUM_DOT = 3;
const NUM_FRAC = 4;
const NUM_EXP = 5;
const NUM_EXP_SIGN = 6;
const NUM_EXP_DIGITS = 7;

/**
 * Streams a top-level JSON object from `stream`, validating RFC 8259 JSON syntax
 * throughout (including skipped and counted values), capturing only the fields the
 * caller asks for up to their size limits, and iterating or counting elements of chosen
 * arrays one by one. Returning `false` from a callback stops and cancels the stream.
 */
export async function scanJsonObject(stream: ReadableStream<Uint8Array>, handlers: ObjectHandlers): Promise<void> {
  const maxKeyChars = handlers.maxKeyChars ?? defaultMaxKeyChars;
  const maxCaptureChars = handlers.maxCaptureChars ?? defaultMaxCaptureChars;
  const maxDepth = handlers.maxDepth ?? defaultMaxDepth;
  const reader = stream.getReader();
  const decoder = new TextDecoder("utf-8");

  const stack: number[] = [];
  let state = ST_ROOT;
  let currentKey = "";
  let arrayMode: ArrayMode = "none";
  let arrayCount = 0;
  let strIsKey = false;
  let strEsc = 0;
  let numState = NUM_INT;
  let litTarget = "";
  let litPos = 0;

  let captureKind: "none" | "key" | "value" | "item" = "none";
  let captureStart = -1;
  let captureLen = 0;
  let captureLimit = 0;
  let captureParts: string[] = [];
  let stopped = false;

  const beginCapture = (kind: "key" | "value" | "item", index: number, limit: number) => {
    captureKind = kind;
    captureParts = [];
    captureStart = index;
    captureLen = 0;
    captureLimit = limit;
  };
  const finishCapture = (chunk: string, end: number): string => {
    const added = end - captureStart;
    if (captureLen + added > captureLimit) {
      captureParts = [];
      captureStart = -1;
      captureLen = 0;
      captureKind = "none";
      throw new RangeError("Captured JSON value exceeds size limit");
    }
    const tail = chunk.slice(captureStart, end);
    const text = captureParts.length === 0 ? tail : (captureParts.push(tail), captureParts.join(""));
    captureParts = [];
    captureStart = -1;
    captureLen = 0;
    captureKind = "none";
    return text;
  };
  const unexpected = (ch: string) => new SyntaxError(`Unexpected character ${JSON.stringify(ch)} in JSON`);

  const finishValue = (chunk: string, end: number) => {
    const depth = stack.length;
    if (captureKind === "value" && depth === 1) {
      const raw = finishCapture(chunk, end);
      if (handlers.onValue?.(currentKey, raw) === false) stopped = true;
    } else if (captureKind === "item" && depth === 2) {
      const raw = finishCapture(chunk, end);
      arrayCount++;
      if (handlers.onItem?.(currentKey, raw) === false) stopped = true;
    } else if (depth === 2 && arrayMode === "count") {
      arrayCount++;
    }
    if (depth === 0) state = ST_DONE;
    else if (stack[depth - 1] === CONTAINER_OBJ) state = ST_OBJ_AFTER;
    else state = ST_ARR_AFTER;
  };

  const startValue = (ch: string, code: number, i: number) => {
    if (!isValueStart(code)) throw unexpected(ch);
    if (stack.length === 1) {
      const action = handlers.onKey(currentKey, ch);
      if ((action === "items" || action === "count") && ch === "[") {
        arrayMode = action;
        arrayCount = 0;
      } else if (action === "capture" || typeof action === "object") {
        beginCapture("value", i, typeof action === "object" ? action.capture : maxCaptureChars);
      }
    } else if (stack.length === 2 && arrayMode === "items") {
      beginCapture("item", i, maxCaptureChars);
    }

    if (ch === "{") {
      if (stack.length >= maxDepth) throw new RangeError("JSON nesting exceeds depth limit");
      stack.push(CONTAINER_OBJ);
      state = ST_OBJ_FIRST;
    } else if (ch === "[") {
      if (stack.length >= maxDepth) throw new RangeError("JSON nesting exceeds depth limit");
      stack.push(CONTAINER_ARR);
      state = ST_ARR_FIRST;
    } else if (ch === "\"") {
      strIsKey = false;
      strEsc = 0;
      state = ST_STRING;
    } else if (ch === "-") {
      numState = NUM_SIGN;
      state = ST_NUMBER;
    } else if (code === 0x30) {
      numState = NUM_ZERO;
      state = ST_NUMBER;
    } else if (isDigit(code)) {
      numState = NUM_INT;
      state = ST_NUMBER;
    } else if (ch === "t") {
      litTarget = "true";
      litPos = 1;
      state = ST_LITERAL;
    } else if (ch === "f") {
      litTarget = "false";
      litPos = 1;
      state = ST_LITERAL;
    } else {
      litTarget = "null";
      litPos = 1;
      state = ST_LITERAL;
    }
  };

  const processChunk = (chunk: string) => {
    for (let i = 0; i < chunk.length && !stopped; i++) {
      const code = chunk.charCodeAt(i);
      const ch = chunk[i]!;
      switch (state) {
        case ST_ROOT:
          if (isSpace(code)) break;
          if (ch !== "{") throw unexpected(ch);
          stack.push(CONTAINER_OBJ);
          state = ST_OBJ_FIRST;
          break;
        case ST_OBJ_FIRST:
          if (isSpace(code)) break;
          if (ch === "}") {
            stack.pop();
            finishValue(chunk, i + 1);
            break;
          }
          if (ch !== "\"") throw unexpected(ch);
          strIsKey = true;
          strEsc = 0;
          if (stack.length === 1) beginCapture("key", i, maxKeyChars);
          state = ST_STRING;
          break;
        case ST_OBJ_KEY:
          if (isSpace(code)) break;
          if (ch !== "\"") throw unexpected(ch);
          strIsKey = true;
          strEsc = 0;
          if (stack.length === 1) beginCapture("key", i, maxKeyChars);
          state = ST_STRING;
          break;
        case ST_OBJ_COLON:
          if (isSpace(code)) break;
          if (ch !== ":") throw unexpected(ch);
          state = ST_VALUE;
          break;
        case ST_VALUE:
          if (isSpace(code)) break;
          startValue(ch, code, i);
          break;
        case ST_OBJ_AFTER:
          if (isSpace(code)) break;
          if (ch === ",") {
            state = ST_OBJ_KEY;
          } else if (ch === "}") {
            stack.pop();
            finishValue(chunk, i + 1);
          } else {
            throw unexpected(ch);
          }
          break;
        case ST_ARR_FIRST:
          if (isSpace(code)) break;
          if (ch === "]") {
            stack.pop();
            if (stack.length === 1 && arrayMode !== "none") {
              const mode = arrayMode;
              arrayMode = "none";
              if (mode === "count" && handlers.onCount?.(currentKey, 0) === false) stopped = true;
            }
            finishValue(chunk, i + 1);
            break;
          }
          startValue(ch, code, i);
          break;
        case ST_ARR_AFTER:
          if (isSpace(code)) break;
          if (ch === ",") {
            state = ST_VALUE;
          } else if (ch === "]") {
            stack.pop();
            if (stack.length === 1 && arrayMode !== "none") {
              const mode = arrayMode;
              arrayMode = "none";
              if (mode === "count" && handlers.onCount?.(currentKey, arrayCount) === false) stopped = true;
            }
            finishValue(chunk, i + 1);
          } else {
            throw unexpected(ch);
          }
          break;
        case ST_STRING:
          if (strEsc === 0) {
            if (ch === "\"") {
              if (strIsKey) {
                if (stack.length === 1) currentKey = JSON.parse(finishCapture(chunk, i + 1)) as string;
                state = ST_OBJ_COLON;
              } else {
                finishValue(chunk, i + 1);
              }
            } else if (ch === "\\") {
              strEsc = 1;
            } else if (code < 0x20) {
              throw unexpected(ch);
            }
          } else if (strEsc === 1) {
            if (
              ch === "\"" || ch === "\\" || ch === "/"
              || ch === "b" || ch === "f" || ch === "n" || ch === "r" || ch === "t"
            ) {
              strEsc = 0;
            } else if (ch === "u") {
              strEsc = 2;
            } else {
              throw unexpected(ch);
            }
          } else {
            if (!isHex(code)) throw unexpected(ch);
            strEsc = strEsc === 5 ? 0 : strEsc + 1;
          }
          break;
        case ST_NUMBER:
          if (numState === NUM_SIGN) {
            if (code === 0x30) numState = NUM_ZERO;
            else if (isDigit(code)) numState = NUM_INT;
            else throw unexpected(ch);
          } else if (numState === NUM_ZERO) {
            if (ch === ".") numState = NUM_DOT;
            else if (ch === "e" || ch === "E") numState = NUM_EXP;
            else if (isSpace(code) || ch === "," || ch === "}" || ch === "]") { finishValue(chunk, i); i--; }
            else throw unexpected(ch);
          } else if (numState === NUM_INT) {
            if (isDigit(code)) break;
            if (ch === ".") numState = NUM_DOT;
            else if (ch === "e" || ch === "E") numState = NUM_EXP;
            else if (isSpace(code) || ch === "," || ch === "}" || ch === "]") { finishValue(chunk, i); i--; }
            else throw unexpected(ch);
          } else if (numState === NUM_DOT) {
            if (isDigit(code)) numState = NUM_FRAC;
            else throw unexpected(ch);
          } else if (numState === NUM_FRAC) {
            if (isDigit(code)) break;
            if (ch === "e" || ch === "E") numState = NUM_EXP;
            else if (isSpace(code) || ch === "," || ch === "}" || ch === "]") { finishValue(chunk, i); i--; }
            else throw unexpected(ch);
          } else if (numState === NUM_EXP) {
            if (ch === "+" || ch === "-") numState = NUM_EXP_SIGN;
            else if (isDigit(code)) numState = NUM_EXP_DIGITS;
            else throw unexpected(ch);
          } else if (numState === NUM_EXP_SIGN) {
            if (isDigit(code)) numState = NUM_EXP_DIGITS;
            else throw unexpected(ch);
          } else {
            if (isDigit(code)) break;
            if (isSpace(code) || ch === "," || ch === "}" || ch === "]") { finishValue(chunk, i); i--; }
            else throw unexpected(ch);
          }
          break;
        case ST_LITERAL:
          if (code !== litTarget.charCodeAt(litPos)) throw unexpected(ch);
          litPos++;
          if (litPos === litTarget.length) finishValue(chunk, i + 1);
          break;
        case ST_DONE:
          if (!isSpace(code)) throw unexpected(ch);
          break;
      }
    }
    if (!stopped && captureStart >= 0) {
      const added = chunk.length - captureStart;
      if (captureLen + added > captureLimit) {
        captureParts = [];
        captureStart = -1;
        captureLen = 0;
        captureKind = "none";
        throw new RangeError("Captured JSON value exceeds size limit");
      }
      captureParts.push(chunk.slice(captureStart));
      captureLen += added;
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
      if (state !== ST_DONE) throw new SyntaxError("Unexpected end of JSON input");
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
    onKey: (key, firstChar) => {
      if (key === "osmId") {
        osmId = null;
        return isNumberStart(firstChar) ? { capture: cityOsmIdMaxChars } : "skip";
      }
      if (key === "name") {
        name = "";
        return firstChar === "\"" ? { capture: cityNameMaxChars } : "skip";
      }
      if (key === "visited") {
        walkedTiles = 0;
        return firstChar === "[" ? "count" : "skip";
      }
      return "skip";
    },
    onValue: (key, json) => {
      const value: unknown = JSON.parse(json);
      if (key === "osmId") osmId = typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : null;
      if (key === "name") name = typeof value === "string" ? value : "";
    },
    onCount: (_key, count) => { walkedTiles = count; },
  });
  return { osmId, name, walkedTiles };
}

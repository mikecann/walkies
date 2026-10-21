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

export function walkableQuery(boundary: PlaceData["boundary"]): string {
  const outer = boundary.flatMap((polygon) => polygon[0]);
  const south = Math.min(...outer.map((p) => p[1]));
  const west = Math.min(...outer.map((p) => p[0]));
  const north = Math.max(...outer.map((p) => p[1]));
  const east = Math.max(...outer.map((p) => p[0]));
  // Keep this query in step with OSMClient.walkableWays. `out geom` brings every
  // tag, which isWalkable needs (sidewalk, foot, maxspeed) before the ways are stored.
  return `[out:json][timeout:120];
way["highway"]["highway"!~"^(${excluded})$"]["access"!~"^(private|no)$"]["foot"!~"^(private|no)$"](${south},${west},${north},${east});
out geom;`;
}

export function waysFromOverpass(value: unknown): PlaceData["ways"] {
  const response = object(value);
  // Overpass can return HTTP 200 with a timeout remark and incomplete elements.
  if (response.remark || !Array.isArray(response.elements)) throw new Error("Incomplete Overpass response");
  return response.elements.flatMap((value) => {
    const element = object(value);
    if (element.type !== "way" || !Array.isArray(element.geometry)) return [];
    const tags = object(element.tags ?? {});
    if (!isWalkable(tags)) return [];
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
    return [way];
  });
}

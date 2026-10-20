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
  // Keep this query in step with OSMClient.walkableWays.
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
    if (typeof tags.highway !== "string" || excludedHighways.has(tags.highway)
      || tags.access === "private" || tags.access === "no" || tags.foot === "private" || tags.foot === "no") return [];
    const way: PlaceData["ways"][number] = {
      highway: tags.highway,
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

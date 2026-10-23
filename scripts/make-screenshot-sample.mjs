#!/usr/bin/env node
// Makes the sample suburb for App Store screenshots (scripts/screenshots.sh): a real
// suburb's OpenStreetMap boundary and walkable streets, in the same compact format as
// the shared street cache (convex/placeData.ts), saved to appstore/sample/<name>.json.
// It's Fremantle, WA by default: pretty from above, and nowhere near Mike's own walks.
//
//   node scripts/make-screenshot-sample.mjs                 # Fremantle (relation 11689400)
//   node scripts/make-screenshot-sample.mjs 11689400 fremantle
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { boundaryFromNominatim, walkableQuery, waysFromOverpass } from "../convex/placeData.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const osmId = Number(process.argv[2] ?? 11689400);
const slug = process.argv[3] ?? "fremantle";
const headers = { "User-Agent": "Walkies screenshots (walkies@mikecann.app)" };

const params = new URLSearchParams({ osm_ids: `R${osmId}`, format: "jsonv2", polygon_geojson: "1", polygon_threshold: "0.0001" });
const lookup = await fetch(`https://nominatim.openstreetmap.org/lookup?${params}`, { headers });
if (!lookup.ok) throw new Error(`Nominatim: ${lookup.status}`);
const { name, boundary } = boundaryFromNominatim(await lookup.json(), osmId);
console.log(`${name}: ${boundary.length} polygon(s)`);

const body = new URLSearchParams({ data: walkableQuery(boundary) }).toString();
let ways;
for (const endpoint of ["https://overpass-api.de/api/interpreter", "https://maps.mail.ru/osm/tools/overpass/api/interpreter"]) {
  try {
    const res = await fetch(endpoint, { method: "POST", headers: { ...headers, "Content-Type": "application/x-www-form-urlencoded" }, body });
    if (!res.ok) throw new Error(`${res.status}`);
    ways = waysFromOverpass(await res.json());
    break;
  } catch (error) {
    console.error(`${endpoint}: ${error.message}`);
  }
}
if (!ways) throw new Error("No street data");
// Five decimal places is about a metre, plenty for tiles and keeps the file small.
const round = (n) => Math.round(n * 1e5) / 1e5;
const data = {
  name,
  osmId,
  boundary: boundary.map((polygon) => polygon.map((ring) => ring.map(([lon, lat]) => [round(lon), round(lat)]))),
  ways: ways.map((way) => ({ ...way, points: way.points.map(([lat, lon]) => [round(lat), round(lon)]) })),
};
const out = join(root, "appstore/sample", `${slug}.json`);
writeFileSync(out, JSON.stringify(data));
console.log(`${ways.length} ways → ${out}`);

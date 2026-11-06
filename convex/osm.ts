// Fetching from OpenStreetMap, shared by places.ts and the Node action in
// placeStreets.ts. Plain code with no Convex functions, so both runtimes can import it.

export const userAgent = "Walkies/0.1 (iOS walking app; https://github.com/mikecann/walkies)";
export const overpassEndpoints = [
  "https://overpass-api.de/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];

export async function fetchJSON(url: string, timeout: number, init?: RequestInit): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(url, { ...init, headers: { "User-Agent": userAgent, "Accept-Language": "en", ...init?.headers }, signal: controller.signal });
    if (!response.ok) throw new Error(`OSM returned ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

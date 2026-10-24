// The checks a researched secret has to pass that don't need a model: is the quote
// really on the page, does the story need Mike's OK, and is its pin somewhere you can
// walk to. Plain functions, so the tests can run them directly.
import type { PlaceData } from "./placeData";

const userAgent = "Mozilla/5.0 (compatible; WalkiesBot/0.1; +https://walkies.mikecann.app)";
const maxBytes = 3_000_000;

export type Page =
  | { ok: true; url: string; title: string; text: string }
  | { ok: false; url: string; reason: string };

/**
 * A web page as plain text. Research and the quote check both read pages through
 * this, so a quote the researcher copied is checked against the same text it saw.
 * PDFs and images come back as not readable: there's no PDF reader here, and a quote
 * nobody can check doesn't count.
 */
export async function fetchPage(url: string, timeout = 20_000): Promise<Page> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return { ok: false, url, reason: "not a web address" };
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return { ok: false, url, reason: "not a web address" };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(parsed, {
      headers: { "User-Agent": userAgent, Accept: "text/html,application/json,text/plain;q=0.9,*/*;q=0.5", "Accept-Language": "en" },
      redirect: "follow",
      signal: controller.signal,
    });
    if (!response.ok) return { ok: false, url, reason: `the site answered ${response.status}` };
    const type = response.headers.get("content-type") ?? "";
    if (/pdf/i.test(type) || /\.pdf($|\?)/i.test(parsed.pathname)) return { ok: false, url, reason: "it's a PDF, which can't be checked here" };
    if (!/html|json|text|xml/i.test(type)) return { ok: false, url, reason: `it's ${type || "not a web page"}` };
    const raw = (await response.text()).slice(0, maxBytes);
    if (/json/i.test(type)) return { ok: true, url: response.url || url, title: "", text: jsonText(raw) };
    if (/html|xml/i.test(type)) {
      const { title, text } = htmlText(raw);
      return { ok: true, url: response.url || url, title, text };
    }
    return { ok: true, url: response.url || url, title: "", text: collapse(raw) };
  } catch (error) {
    return { ok: false, url, reason: controller.signal.aborted ? "it took too long to load" : `it wouldn't load (${String(error).slice(0, 80)})` };
  } finally {
    clearTimeout(timer);
  }
}

/** JSON records (Landgate's and the heritage layers' ArcGIS answers) as readable lines. */
function jsonText(raw: string): string {
  try {
    const lines: string[] = [];
    const walk = (value: unknown, key: string) => {
      if (value === null || value === undefined) return;
      if (Array.isArray(value)) value.forEach((item) => walk(item, key));
      else if (typeof value === "object") for (const [k, v] of Object.entries(value)) walk(v, k);
      else lines.push(`${key}: ${String(value)}`);
    };
    walk(JSON.parse(raw), "");
    return collapse(lines.join("\n"));
  } catch {
    return collapse(raw);
  }
}

const entities: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", ndash: "–", mdash: "—", hellip: "…",
  lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", deg: "°", eacute: "é", egrave: "è", aacute: "á", copy: "©",
};
export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, code: string) => {
    if (code[0] === "#") {
      const n = code[1] === "x" || code[1] === "X" ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n < 0x110000 ? String.fromCodePoint(n) : match;
    }
    return entities[code.toLowerCase()] ?? match;
  });
}

const collapse = (text: string) => text.replace(/[ \t\f\v ]+/g, " ").replace(/\s*\n\s*/g, "\n").replace(/\n{3,}/g, "\n\n").trim();

/** The readable text of an HTML page: no scripts, styles, menus or footers. */
export function htmlText(html: string): { title: string; text: string } {
  const title = decodeEntities(html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "").replace(/\s+/g, " ").trim();
  const body = html
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<(script|style|noscript|svg|template|iframe|head|nav|footer|form)\b[\s\S]*?<\/\1>/gi, " ")
    .replace(/<(br|\/p|\/div|\/li|\/h\d|\/tr|\/section|\/article|\/blockquote|\/dd|\/dt)\b[^>]*>/gi, "\n")
    .replace(/<[^>]+>/g, " ");
  return { title, text: collapse(decodeEntities(body)) };
}

/**
 * Lower case letters and digits only, one space between words, with a map back to
 * where each character came from. Curly quotes, dashes, accents, line breaks and
 * punctuation can't make a real quote miss.
 */
function normalise(text: string): { flat: string; at: number[] } {
  let flat = "";
  const at: number[] = [];
  let space = true;
  for (let i = 0; i < text.length; i++) {
    const char = text[i]!.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase();
    if (/^[a-z0-9]+$/.test(char)) {
      flat += char;
      for (let k = 0; k < char.length; k++) at.push(i);
      space = false;
    } else if (!space && !/^['’‘`]$/.test(char)) {
      // Apostrophes join words ("don't" is "dont"), so a quote typed without one still matches.
      flat += " ";
      at.push(i);
      space = true;
    }
  }
  return { flat: flat.trimEnd(), at };
}

/** Quotes shorter than this prove nothing: "the jetty" is on every page about it. */
export const minQuote = 24;

/**
 * Whether `quote` is really on the page, and the page text around it for the
 * fact-checker. An ellipsis in the quote stands for words left out, so each part has
 * to be there, in order, within a few hundred characters of the last.
 */
export function findQuote(text: string, quote: string): { found: boolean; context?: string } {
  const page = normalise(text);
  const parts = quote.split(/\.\.\.|…|\[\.\.\.\]/).map((part) => normalise(part).flat.trim()).filter(Boolean);
  if (parts.join(" ").length < minQuote) return { found: false };
  let from = 0;
  let start = -1;
  let end = -1;
  for (const part of parts) {
    const index = page.flat.indexOf(part, from);
    if (index < 0 || (start >= 0 && index - end > 400)) return { found: false };
    if (start < 0) start = index;
    end = index + part.length;
    from = end;
  }
  const first = page.at[start]!;
  const last = page.at[Math.max(start, end - 1)]!;
  return { found: true, context: text.slice(Math.max(0, first - 600), last + 600).trim() };
}

/** Ways of saying someone died or a crime happened. Matching sends the story to Mike. */
const deathOrCrime = /\b(die[sd]?|dying|death|deaths|dead|deceased|kill(ed|ing|s)?|murder\w*|massacre\w*|slaughter\w*|hang(ed|ing)|executed|execution|drown\w*|suicide|perish\w*|fatal\w*|buried|burial|graves?|cemetery|funeral|crimes?|criminal|convict(ed|s)?|prison\w*|gaol\w*|jail\w*|stole|stolen|theft|robb\w*|arson|assault\w*|manslaughter|inquest|shot|shooting|bushrang\w*)\b/i;
const firstNations = /\b(aborigin\w*|indigenous|first nations|traditional owners?|noongar|nyoongar|nyungar|wardandi|wadandi|whadjuk|dreaming|elders?|torres strait|songlines?|song-lines?|boodja|moort)\b/i;

/** Sensitive subjects the text itself shows, on top of what the writer and checker flagged. */
export function sensitiveWords(text: string): string[] {
  const found: string[] = [];
  if (firstNations.test(text)) found.push("first-nations");
  if (deathOrCrime.test(text)) found.push("death-or-crime");
  return found;
}

/** Whether `url` is on one of the domains, where ".wa.gov.au" means any site under it. */
export function onDomains(url: string, domains: readonly string[]): boolean {
  let host: string;
  try {
    host = new URL(url).hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return false;
  }
  return domains.some((domain) => domain.startsWith(".") ? host.endsWith(domain) || host === domain.slice(1) : host === domain || host.endsWith(`.${domain}`));
}

// Pins. Boundaries are GeoJSON ([lon, lat]); street points are [lat, lon], as the phones keep them.

function inRing(ring: number[][], lon: number, lat: number): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i]!;
    const [xj, yj] = ring[j]!;
    if ((yi! > lat) !== (yj! > lat) && lon < ((xj! - xi!) * (lat - yi!)) / (yj! - yi!) + xi!) inside = !inside;
  }
  return inside;
}

/** Inside the suburb: inside one of its outlines and not in that outline's holes. */
export function insideBoundary(boundary: PlaceData["boundary"], lat: number, lon: number): boolean {
  return boundary.some(([outer, ...holes]) => outer !== undefined && inRing(outer, lon, lat) && !holes.some((hole) => inRing(hole, lon, lat)));
}

/** The point on a walkable way nearest to a spot, and how far away it is in metres. */
export function nearestStreet(ways: PlaceData["ways"], lat: number, lon: number): { metres: number; lat: number; lon: number } | null {
  // Metres east and north of the spot. Flat-earth is plenty over a few hundred metres.
  const kx = 111_320 * Math.cos((lat * Math.PI) / 180);
  const ky = 110_540;
  let best: { metres: number; lat: number; lon: number } | null = null;
  for (const way of ways) {
    for (let i = 0; i + 1 < way.points.length; i++) {
      const [alat, alon] = way.points[i]!;
      const [blat, blon] = way.points[i + 1]!;
      const ax = (alon! - lon) * kx, ay = (alat! - lat) * ky;
      const bx = (blon! - lon) * kx, by = (blat! - lat) * ky;
      const dx = bx - ax, dy = by - ay;
      const length = dx * dx + dy * dy;
      const t = length === 0 ? 0 : Math.max(0, Math.min(1, -(ax * dx + ay * dy) / length));
      const x = ax + t * dx, y = ay + t * dy;
      const metres = Math.hypot(x, y);
      if (best === null || metres < best.metres) best = { metres, lat: lat + y / ky, lon: lon + x / kx };
    }
  }
  return best;
}

const round6 = (n: number) => Math.round(n * 1e6) / 1e6;

/**
 * Where a story's pin ends up: on the nearest walkable way inside the suburb, so it's
 * never in the sea or on someone's lot. Null means scatter it over the suburb instead.
 */
export function placePin(data: PlaceData, lat: number, lon: number, maxMetres: number): { pin: { lat: number; lon: number } | null; note: string } {
  if (!insideBoundary(data.boundary, lat, lon)) return { pin: null, note: "Its spot is outside the suburb, so it's scattered over the streets instead." };
  const street = nearestStreet(data.ways, lat, lon);
  if (street === null || street.metres > maxMetres) {
    return { pin: null, note: `Its spot is more than ${maxMetres} m from any walkable street, so it's scattered instead.` };
  }
  if (!insideBoundary(data.boundary, street.lat, street.lon)) {
    return { pin: { lat: round6(lat), lon: round6(lon) }, note: "Its nearest street is over the border, so the pin stays where it was." };
  }
  const moved = Math.round(street.metres);
  return {
    pin: { lat: round6(street.lat), lon: round6(street.lon) },
    note: moved < 2 ? "Its pin is on a walkable street." : `Its pin moved ${moved} m onto the nearest walkable street.`,
  };
}

/** A bounding box around the outlines, for Nominatim's `viewbox`. */
export function boundingBox(boundary: PlaceData["boundary"]): { south: number; west: number; north: number; east: number } {
  const points = boundary.flatMap((polygon) => polygon[0] ?? []);
  return {
    south: Math.min(...points.map((p) => p[1]!)), north: Math.max(...points.map((p) => p[1]!)),
    west: Math.min(...points.map((p) => p[0]!)), east: Math.max(...points.map((p) => p[0]!)),
  };
}

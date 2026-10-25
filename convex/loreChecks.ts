// The checks a researched secret has to pass that don't need a model: is the quote
// really on the page, does the story need Mike's OK, and is its pin somewhere you can
// walk to. Plain functions, so the tests can run them directly.
import { leadOnlySources } from "./loreConfig";
import type { PlaceData } from "./placeData";

const userAgent = "Mozilla/5.0 (compatible; WalkiesBot/0.1; +https://walkies.mikecann.app)";
/** Bytes of a page read before the rest is cut off. Convex runtime actions have 64 MiB,
 * and turning HTML into text makes a few copies of it. */
export const maxBytes = 2_000_000;
/** Characters of a page's text kept, which is also all a quote can be checked against. */
export const maxText = 200_000;
const maxRedirects = 5;

export type Page =
  | { ok: true; url: string; title: string; text: string }
  | { ok: false; url: string; reason: string };

// Names that only mean something inside a network, never a public website.
const privateSuffixes = [".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".home.arpa", ".corp", ".private", ".onion"];

/**
 * Whether the pipeline may open this address, as an https URL. The model picks these,
 * so only public websites on the usual port: no IP addresses at all (the URL parser
 * turns every way of writing one, like 2130706433 or 0x7f.1, into its dotted or
 * bracketed form first), no localhost or internal names, no logins in the URL. Plain
 * http is tried as https, which is also what stops a public name that points at an
 * internal address from reaching anything without a real certificate for it.
 */
export function checkUrl(raw: string): { ok: true; url: URL } | { ok: false; reason: string } {
  let url: URL;
  try {
    url = new URL(raw.trim().replace(/^http:/i, "https:"));
  } catch {
    return { ok: false, reason: "not a web address" };
  }
  if (url.protocol !== "https:") return { ok: false, reason: "not a web address" };
  if (url.username || url.password) return { ok: false, reason: "it has a login in it" };
  if (url.port !== "") return { ok: false, reason: "it's on an unusual port" };
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (host.startsWith("[") || /^\d+\.\d+\.\d+\.\d+$/.test(host)) return { ok: false, reason: "it's an IP address, not a website" };
  if (!host.includes(".") || host === "localhost" || privateSuffixes.some((suffix) => host.endsWith(suffix))) {
    return { ok: false, reason: "it isn't a public website" };
  }
  return { ok: true, url };
}

/** The body as text, reading no more than `limit` bytes: the rest is never downloaded. */
async function readCapped(response: Response, limit: number): Promise<string> {
  const charset = response.headers.get("content-type")?.match(/charset=["']?([\w-]+)/i)?.[1];
  let decoder: TextDecoder;
  try {
    decoder = new TextDecoder(charset ?? "utf-8");
  } catch {
    decoder = new TextDecoder("utf-8");
  }
  const reader = response.body?.getReader();
  if (!reader) return "";
  let text = "";
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    const room = limit - size;
    if (value.length >= room) {
      text += decoder.decode(value.subarray(0, room));
      await reader.cancel().catch(() => undefined);
      break;
    }
    size += value.length;
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

/**
 * A web page as plain text. Research and the quote check both read pages through
 * this, so a quote the researcher copied is checked against the same text it saw.
 * Redirects are followed by hand, each one checked like the first address. PDFs and
 * images come back as not readable: there's no PDF reader here, and a quote nobody
 * can check doesn't count.
 */
export async function fetchPage(url: string, timeout = 20_000): Promise<Page> {
  const first = checkUrl(url);
  if (!first.ok) return { ok: false, url, reason: first.reason };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    let current = first.url;
    let response: Response;
    for (let hop = 0; ; hop++) {
      response = await fetch(current, {
        headers: { "User-Agent": userAgent, Accept: "text/html,application/json,text/plain;q=0.9,*/*;q=0.5", "Accept-Language": "en" },
        redirect: "manual",
        signal: controller.signal,
      });
      const location = response.status >= 300 && response.status < 400 ? response.headers.get("location") : null;
      if (location === null) {
        // A runtime that won't hand over redirects says so this way; never follow those blind.
        if (response.type === "opaqueredirect") return { ok: false, url, reason: "it redirects somewhere that can't be checked" };
        break;
      }
      await response.body?.cancel().catch(() => undefined);
      if (hop >= maxRedirects) return { ok: false, url, reason: "it redirects too many times" };
      let target: string;
      try {
        target = new URL(location, current).href;
      } catch {
        return { ok: false, url, reason: "it redirects to something that isn't a web address" };
      }
      const next = checkUrl(target);
      if (!next.ok) return { ok: false, url, reason: `it redirects somewhere it can't go (${next.reason})` };
      current = next.url;
    }
    const finalUrl = current.href;
    if (!response.ok) {
      await response.body?.cancel().catch(() => undefined);
      return { ok: false, url, reason: `the site answered ${response.status}` };
    }
    const type = response.headers.get("content-type") ?? "";
    const pdf = /pdf/i.test(type) || /\.pdf($|\?)/i.test(current.pathname);
    if (pdf || !/html|json|text|xml/i.test(type)) {
      await response.body?.cancel().catch(() => undefined);
      return { ok: false, url, reason: pdf ? "it's a PDF, which can't be checked here" : `it's ${type || "not a web page"}` };
    }
    const raw = await readCapped(response, maxBytes);
    const page = /json/i.test(type) ? { title: "", text: jsonText(raw) }
      : /html|xml/i.test(type) ? htmlText(raw) : { title: "", text: collapse(raw) };
    return { ok: true, url: finalUrl, title: page.title, text: page.text.slice(0, maxText) };
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
/** Each part of a quote with an ellipsis has to be a real phrase on its own, or "the ...
 * jetty ... was ... built" would match almost any page. */
export const minPart = { chars: 12, words: 3 };

// Words that flip or soften what's either side of them. An ellipsis can't leave these
// out: "was ... the longest" from "was never the longest" says the opposite. Spelled as
// normalise leaves them, so "wasn't" is "wasnt".
const turns = new Set([
  "no", "not", "never", "none", "nor", "neither", "nobody", "nothing", "nowhere", "cannot", "cant", "without",
  "isnt", "wasnt", "arent", "werent", "dont", "doesnt", "didnt", "hasnt", "havent", "hadnt", "wont", "wouldnt",
  "couldnt", "shouldnt", "mustnt", "neednt", "aint", "hardly", "barely", "scarcely", "seldom", "rarely", "false",
  "untrue", "myth", "denied", "denies", "disputed", "unproven", "unconfirmed", "allegedly", "reportedly",
  "supposedly", "reputedly", "probably", "possibly", "perhaps", "maybe", "believed", "thought", "rumoured",
  "rumored", "legend", "unlikely", "former", "formerly", "once",
]);

/** Where `part` is in `flat` at or after `from` as whole words, or -1. */
function wholeWords(flat: string, part: string, from: number): number {
  for (let index = flat.indexOf(part, from); index >= 0; index = flat.indexOf(part, index + 1)) {
    const end = index + part.length;
    if ((index === 0 || flat[index - 1] === " ") && (end === flat.length || flat[end] === " ")) return index;
  }
  return -1;
}

/**
 * Whether `quote` is really on the page, and the page text around it for the
 * fact-checker. It has to match whole words. An ellipsis stands for words left out, so
 * each part has to be there, in order, within a few hundred characters of the last;
 * each part has to be a phrase of its own (`minPart`), and the words left out can't
 * include a negation or a hedge (`turns`).
 */
export function findQuote(text: string, quote: string): { found: boolean; context?: string } {
  const page = normalise(text);
  const parts = quote.split(/\.\.\.|…|\[\.\.\.\]/).map((part) => normalise(part).flat.trim()).filter(Boolean);
  if (parts.join(" ").length < minQuote) return { found: false };
  if (parts.length > 1 && parts.some((part) => part.length < minPart.chars || part.split(" ").length < minPart.words)) return { found: false };
  let from = 0;
  let start = -1;
  let end = -1;
  for (const part of parts) {
    const index = wholeWords(page.flat, part, from);
    if (index < 0 || (start >= 0 && index - end > 400)) return { found: false };
    if (start >= 0 && page.flat.slice(end, index).split(" ").some((word) => turns.has(word))) return { found: false };
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

const host = (url: string) => {
  try {
    return new URL(url).hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return "";
  }
};

/** Whether a source is Wikipedia or a site anyone can write on (leadOnlySources). */
export const leadOnly = (url: string) => onDomains(url, leadOnlySources);

/**
 * Why a secret's sources aren't enough, or null. A claim citing a lead-only site only
 * counts when another of its claims comes from a different site that isn't one.
 */
export function leadOnlyProblem(urls: string[]): string | null {
  const leads = urls.filter(leadOnly);
  if (leads.length === 0) return null;
  const backed = leads.every((lead) => urls.some((url) => !leadOnly(url) && host(url) !== host(lead)));
  return backed ? null : `It leans on ${[...new Set(leads.map(host))].join(", ")}, which only counts as a lead, with nothing from another site behind it.`;
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

/**
 * The point on a walkable way nearest to a spot, and how far away it is in metres.
 * With `inside`, only points that pass it count: where a way crosses the border, the
 * nearest point on it can be outside while a few metres along it is in.
 */
export function nearestStreet(
  ways: PlaceData["ways"], lat: number, lon: number, inside?: { test: (lat: number, lon: number) => boolean; within: number },
): { metres: number; lat: number; lon: number } | null {
  // Metres east and north of the spot. Flat-earth is plenty over a few hundred metres.
  const kx = 111_320 * Math.cos((lat * Math.PI) / 180);
  const ky = 110_540;
  let best: { metres: number; lat: number; lon: number } | null = null;
  const consider = (x: number, y: number) => {
    const metres = Math.hypot(x, y);
    if (best !== null && metres >= best.metres) return;
    const point = { metres, lat: lat + y / ky, lon: lon + x / kx };
    if (inside && !inside.test(point.lat, point.lon)) return;
    best = point;
  };
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
      if (!inside) {
        consider(x, y);
        continue;
      }
      // Nothing on this segment is close enough.
      if (Math.hypot(x, y) > inside.within) continue;
      consider(x, y);
      // Every 5 m along it as well, for the part that's over the border.
      const steps = Math.min(400, Math.ceil(Math.sqrt(length) / 5));
      for (let k = 0; k <= steps; k++) consider(ax + (dx * k) / steps, ay + (dy * k) / steps);
    }
  }
  return best;
}

const round6 = (n: number) => Math.round(n * 1e6) / 1e6;

/**
 * Where a story's pin ends up: on the nearest walkable way inside the suburb, so it's
 * never in the sea, on someone's lot or over the border. Null means scatter it over
 * the suburb instead.
 */
export function placePin(data: PlaceData, lat: number, lon: number, maxMetres: number): { pin: { lat: number; lon: number } | null; note: string } {
  if (!insideBoundary(data.boundary, lat, lon)) return { pin: null, note: "Its spot is outside the suburb, so it's scattered over the streets instead." };
  const street = nearestStreet(data.ways, lat, lon, { test: (a, b) => insideBoundary(data.boundary, a, b), within: maxMetres });
  if (street === null || street.metres > maxMetres) {
    return { pin: null, note: `Its spot is more than ${maxMetres} m from any walkable street inside the suburb, so it's scattered instead.` };
  }
  const moved = Math.round(street.metres);
  return {
    pin: { lat: round6(street.lat), lon: round6(street.lon) },
    note: moved < 2 ? "Its pin is on a walkable street." : `Its pin moved ${moved} m onto the nearest walkable street inside the suburb.`,
  };
}

/** Square metres inside the outlines, less their holes. Flat-earth around the middle,
 * like the phones' Boundary.area, which is plenty for telling a suburb from a county. */
export function boundaryArea(boundary: PlaceData["boundary"]): number {
  const points = boundary.flatMap((polygon) => polygon[0] ?? []);
  if (points.length === 0) return 0;
  const midLat = points.reduce((sum, p) => sum + p[1]!, 0) / points.length;
  const kx = 111_320 * Math.cos((midLat * Math.PI) / 180);
  const ky = 110_540;
  const ring = (r: number[][]) => Math.abs(r.reduce((sum, p, i) => {
    const q = r[(i + 1) % r.length]!;
    return sum + p[0]! * kx * q[1]! * ky - q[0]! * kx * p[1]! * ky;
  }, 0)) / 2;
  return boundary.reduce((sum, [outer, ...holes]) => sum + (outer ? ring(outer) : 0) - holes.reduce((h, hole) => h + ring(hole), 0), 0);
}

/** A bounding box around the outlines, for Nominatim's `viewbox`. */
export function boundingBox(boundary: PlaceData["boundary"]): { south: number; west: number; north: number; east: number } {
  const points = boundary.flatMap((polygon) => polygon[0] ?? []);
  return {
    south: Math.min(...points.map((p) => p[1]!)), north: Math.max(...points.map((p) => p[1]!)),
    west: Math.min(...points.map((p) => p[0]!)), east: Math.max(...points.map((p) => p[0]!)),
  };
}

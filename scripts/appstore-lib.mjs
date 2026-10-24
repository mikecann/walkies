// What the App Store scripts share: Walkies' App Store Connect app, the API key, and a
// small client. Same team and key as Poddle (a team-wide Admin key); it's read from
// ~/.config/poddle and never printed or copied.
import { createPrivateKey, sign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** "Walkies: Explore Your Suburb" in App Store Connect (App Information > General > Apple ID). */
export const APP_ID = "6826001880";
export const BUNDLE_ID = "com.mikecann.walkies";

export const KEY_ID = process.env.ASC_KEY_ID ?? "7SS6J9F98P";
export const ISSUER = process.env.ASC_ISSUER_ID ?? "69a6de6f-a06e-47e3-e053-5b8c7c11a4d1";
export const KEY_PATH = process.env.ASC_KEY ?? join(homedir(), ".config/poddle", `AuthKey_${KEY_ID}.p8`);
/** The App Review contact's email and phone, kept out of git (shared with Poddle). */
export const REVIEW_CONTACT_FILE = join(homedir(), ".config/poddle/review-contact.json");

/** Stops with a clear message if the API key's missing. */
export function requireApp() {
  if (!existsSync(KEY_PATH)) {
    console.error(`✗ No App Store Connect API key at ${KEY_PATH}`);
    process.exit(1);
  }
}

export function reviewContact() {
  try {
    return JSON.parse(readFileSync(REVIEW_CONTACT_FILE, "utf8"));
  } catch {
    return {};
  }
}

let token;
/** An ES256 JWT for the API, made fresh every 15 minutes. */
export function jwt() {
  const now = Math.floor(Date.now() / 1000);
  if (token && token.exp - now > 60) return token.value;
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = enc({ alg: "ES256", kid: KEY_ID, typ: "JWT" });
  const body = enc({ iss: ISSUER, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" });
  const key = createPrivateKey(readFileSync(KEY_PATH, "utf8"));
  const sig = sign("sha256", Buffer.from(`${head}.${body}`), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  token = { value: `${head}.${body}.${sig}`, exp: now + 15 * 60 };
  return token.value;
}

const API = "https://api.appstoreconnect.apple.com";

export async function api(method, path, body) {
  const res = await fetch(path.startsWith("http") ? path : API + path, {
    method,
    headers: { Authorization: `Bearer ${jwt()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return null;
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const why = json?.errors?.map((e) => `${e.title}: ${e.detail}`).join("; ") ?? text;
    throw new Error(`${method} ${path} → ${res.status} ${why}`);
  }
  return json;
}

export const get = (path) => api("GET", path);

/** Every page of a list. */
export async function getAll(path) {
  const out = [];
  let next = path;
  while (next) {
    const page = await get(next);
    out.push(...page.data);
    next = page.links?.next;
  }
  return out;
}

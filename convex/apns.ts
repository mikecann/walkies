"use node";

// Pushes over APNs: HTTP/2 with the team's token-based (ES256 JWT) auth key, the same
// key Poddle uses (convex.config.ts has the env). Only the iPhone registers for now.

// @ts-expect-error Convex's tsconfig has no Node types, and HTTP/2 (which APNs needs, and fetch doesn't do) is all this file needs from Node.
import http2Module from "node:http2";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { env, internalAction } from "./_generated/server";
import { vPush } from "./devices";

/** The little of node:http2 this file uses. */
type Stream = {
  setEncoding(encoding: "utf8"): void;
  on(event: "response", listener: (headers: Record<string, string | number | undefined>) => void): void;
  on(event: "data", listener: (chunk: string) => void): void;
  on(event: "end", listener: () => void): void;
  on(event: "error", listener: (error: Error) => void): void;
  setTimeout(ms: number, listener: () => void): void;
  close(): void;
  end(body: string): void;
};
type Session = {
  request(headers: Record<string, string>): Stream;
  on(event: "error", listener: (error: Error) => void): void;
  close(): void;
};
const http2 = http2Module as { connect(authority: string): Session };

const topic = "com.mikecann.walkies";
type ApnsEnv = "sandbox" | "production";
type Config = { key: string; keyId: string; teamId: string; env: ApnsEnv };

function config(): Config | null {
  const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_ENV } = env;
  if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID) return null;
  return { key: APNS_KEY_P8, keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID, env: APNS_ENV === "production" ? "production" : "sandbox" };
}

/** The .p8's key as bytes, whether it was pasted as PEM (with real or `\n` newlines) or bare base64. */
function toPkcs8(raw: string) {
  const base64 = raw.replace(/\\n/g, "\n").replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function b64url(data: Uint8Array | string) {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * The provider token, an ES256 JWT. WebCrypto's ECDSA signature is already the raw r||s a JWT
 * wants. Apple wants it refreshed at most every 20 minutes; a fresh one per send is fine at this volume.
 */
async function providerToken(cfg: Config) {
  const input = `${b64url(JSON.stringify({ alg: "ES256", kid: cfg.keyId }))}.${b64url(JSON.stringify({ iss: cfg.teamId, iat: Math.floor(Date.now() / 1000) }))}`;
  const key = await crypto.subtle.importKey("pkcs8", toPkcs8(cfg.key), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${b64url(new Uint8Array(signature))}`;
}

type Result = { token: string; status: number; reason?: string };

function sendOne(session: Session, jwt: string, token: string, payload: string): Promise<Result> {
  return new Promise((resolve) => {
    const req = session.request({
      ":method": "POST", ":path": `/3/device/${token}`, authorization: `bearer ${jwt}`,
      "apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10", "content-type": "application/json",
    });
    let status = 0;
    let body = "";
    req.setEncoding("utf8");
    req.on("response", (headers) => (status = Number(headers[":status"] ?? 0)));
    req.on("data", (chunk: string) => (body += chunk));
    req.on("end", () => {
      let reason: string | undefined;
      try { reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined; } catch { reason = body || undefined; }
      resolve({ token, status, reason });
    });
    req.on("error", (e) => resolve({ token, status: 0, reason: e.message }));
    req.setTimeout(10_000, () => { req.close(); resolve({ token, status: 0, reason: "timeout" }); });
    req.end(payload);
  });
}

async function sendAll(environment: ApnsEnv, jwt: string, tokens: string[], payload: string) {
  const session = http2.connect(environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com");
  session.on("error", (e) => console.error(`[apns] session error: ${e.message}`));
  try {
    return await Promise.all(tokens.map((t) => sendOne(session, jwt, t, payload)));
  } finally {
    session.close();
  }
}

/** One alert to every phone these people are signed in on (devices.sendPushes schedules it). */
export const send = internalAction({
  args: vPush,
  returns: v.null(),
  handler: async (ctx, { userIds, title, body, threadId }) => {
    const cfg = config();
    if (!cfg) {
      console.log(`[apns] not set up, skipping: ${title}: ${body}`);
      return null;
    }
    const targets = await ctx.runQuery(internal.devices.pushTargets, { userIds });
    if (targets.length === 0) return null;
    const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default", "thread-id": threadId } });
    const jwt = await providerToken(cfg);
    const retry: { token: string; environment: ApnsEnv }[] = [];
    for (const environment of ["sandbox", "production"] as const) {
      const tokens = targets.filter((t) => (t.environment ?? cfg.env) === environment).map((t) => t.token);
      if (tokens.length === 0) continue;
      for (const r of await sendAll(environment, jwt, tokens, payload)) {
        if (r.status === 200) continue;
        // A Release build installed from Xcode gets a sandbox token while saying production, which
        // Apple calls BadDeviceToken. So try the other environment before giving up on it.
        if (r.reason === "BadDeviceToken") retry.push({ token: r.token, environment: environment === "production" ? "sandbox" : "production" });
        else {
          console.warn(`[apns] ${r.status} ${r.reason ?? ""} for …${r.token.slice(-6)}`);
          if (r.status === 410 || r.reason === "Unregistered") await ctx.runMutation(internal.devices.dropToken, { token: r.token });
        }
      }
    }
    for (const { token, environment } of retry) {
      const [r] = await sendAll(environment, jwt, [token], payload);
      if (r?.status === 200) await ctx.runMutation(internal.devices.setTokenEnvironment, { token, environment });
      else {
        console.warn(`[apns] BadDeviceToken in both environments for …${token.slice(-6)}`);
        await ctx.runMutation(internal.devices.dropToken, { token });
      }
    }
    return null;
  },
});

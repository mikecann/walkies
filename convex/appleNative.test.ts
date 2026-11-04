/// <reference types="vite/client" />
import { registerCore } from "@convex-dev/auth/test";
import { convexTest } from "convex-test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import { api } from "./_generated/api";
import { APPLE_BUNDLE_ID, sha256Hex } from "./appleIdentityToken";
import schema from "./schema";

// The iPhone's own Sign in with Apple sheet hands the app an identity token (a JWT Apple
// signs, for the app's bundle ID), and auth:signInWithAppleNative swaps it for a session.
// Apple's review devices refuse the web sign-in sheet outright (seen in Poddle), so this is
// the way in that doesn't need a browser.

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);

type KeyPair = Awaited<ReturnType<typeof generateKeyPair>>;
let apple: KeyPair;
let stranger: KeyPair;
let privateKey: string;
let jwks: string;

beforeAll(async () => {
  // Ephemeral keys for this test process only: Apple's (the token signer), someone else's,
  // and Convex Auth's own session-signing key.
  apple = await generateKeyPair("RS256");
  stranger = await generateKeyPair("RS256");
  const session = await generateKeyPair("RS256", { extractable: true });
  const der = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey("pkcs8", session.privateKey as CryptoKey))));
  privateKey = btoa(`-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----`);
  jwks = JSON.stringify({ keys: [{ ...(await exportJWK(session.publicKey)), kid: "test-key" }] });
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

async function setup() {
  vi.stubEnv("CONVEX_SITE_URL", "https://walkies-test.convex.site");
  vi.stubEnv("AUTH_PRIVATE_KEY", privateKey);
  vi.stubEnv("AUTH_JWKS", jwks);
  // Apple's published signing keys.
  const published = { keys: [{ ...(await exportJWK(apple.publicKey)), kid: "apple-1", alg: "RS256", use: "sig" }] };
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string | URL | Request) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      return url === "https://appleid.apple.com/auth/keys" ? Response.json(published) : new Response("not found", { status: 404 });
    }),
  );
  const t = convexTest(schema, modules);
  registerCore(t);
  return t;
}

/** An identity token like the one ASAuthorizationAppleIDCredential carries. */
async function identityToken(
  opts: { sub?: string; email?: string; nonce?: string; aud?: string; iss?: string; expiresIn?: string; key?: KeyPair } = {},
) {
  return await new SignJWT({
    email: opts.email ?? "walker@example.com",
    email_verified: "true",
    nonce: await sha256Hex(opts.nonce ?? "nonce-1"),
  })
    .setProtectedHeader({ alg: "RS256", kid: "apple-1" })
    .setIssuer(opts.iss ?? "https://appleid.apple.com")
    .setAudience(opts.aud ?? APPLE_BUNDLE_ID)
    .setSubject(opts.sub ?? "001234.apple-sub.0001")
    .setIssuedAt()
    .setExpirationTime(opts.expiresIn ?? "10m")
    .sign((opts.key ?? apple).privateKey);
}

type T = Awaited<ReturnType<typeof setup>>;
const users = (t: T) => t.run((ctx) => ctx.db.query("users").collect());

describe("native Sign in with Apple", () => {
  test("a token from Apple signs in, and the first time keeps the name the phone passed on", async () => {
    const t = await setup();
    const result = await t.action(api.auth.signInWithAppleNative, {
      identityToken: await identityToken(),
      nonce: "nonce-1",
      firstName: " Pat ",
      lastName: "Lee",
    });
    expect(result.status).toBe("complete");
    const me = await t.withIdentity({ subject: result.tokens.userId }).query(api.users.me);
    expect(me).toEqual({ name: "Pat Lee", email: "walker@example.com", picture: null });
  });

  test("signing in again is the same person, and a missing name doesn't wipe the saved one", async () => {
    const t = await setup();
    const first = await t.action(api.auth.signInWithAppleNative, {
      identityToken: await identityToken(),
      nonce: "nonce-1",
      firstName: "Pat",
    });
    const again = await t.action(api.auth.signInWithAppleNative, {
      identityToken: await identityToken({ nonce: "nonce-2" }),
      nonce: "nonce-2",
    });
    expect(again.tokens.userId).toBe(first.tokens.userId);
    expect(await users(t)).toHaveLength(1);
    expect((await users(t))[0].name).toBe("Pat");
  });

  test("an account made with Google for the same verified email is the one you get", async () => {
    const t = await setup();
    const googleUser = await t.run((ctx) =>
      ctx.db.insert("users", { name: "Pat", email: "walker@example.com", emailVerified: true }),
    );
    const result = await t.action(api.auth.signInWithAppleNative, { identityToken: await identityToken(), nonce: "nonce-1" });
    expect(result.tokens.userId).toBe(googleUser);
    expect(await users(t)).toHaveLength(1);
  });

  test.each([
    ["signed by someone other than Apple", { key: "stranger" }],
    ["made for another app", { aud: "com.example.other" }],
    ["made for the website's Services ID rather than the app", { aud: "com.mikecann.walkies.signin" }],
    ["from another issuer", { iss: "https://evil.example.com" }],
    ["expired", { expiresIn: "-1m" }],
    ["for a different sign-in attempt (nonce)", { nonce: "someone-elses-nonce" }],
  ])("a token %s is refused and no account is made", async (_why, change) => {
    const t = await setup();
    const { key, ...rest } = change as { key?: string; aud?: string; iss?: string; expiresIn?: string; nonce?: string };
    const token = await identityToken({ ...rest, key: key === "stranger" ? stranger : apple });
    await expect(t.action(api.auth.signInWithAppleNative, { identityToken: token, nonce: "nonce-1" })).rejects.toThrow(
      /Apple didn't confirm/,
    );
    expect(await users(t)).toHaveLength(0);
  });

  test("garbage instead of a token is refused", async () => {
    const t = await setup();
    await expect(t.action(api.auth.signInWithAppleNative, { identityToken: "not-a-jwt", nonce: "nonce-1" })).rejects.toThrow(
      /Apple didn't confirm/,
    );
  });
});

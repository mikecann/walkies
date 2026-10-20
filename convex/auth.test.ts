/// <reference types="vite/client" />
import { registerCore } from "@convex-dev/auth/test";
import { registerAnonymousProvider } from "@convex-dev/auth/components/anonymous/test";
import { convexTest } from "convex-test";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import schema from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);
let privateKey: string;
let jwks: string;

beforeAll(async () => {
  // Ephemeral keys for this test process only. Never read deployment credentials.
  const pair = await crypto.subtle.generateKey({
    name: "RSASSA-PKCS1-v1_5", modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256",
  }, true, ["sign", "verify"]);
  const der = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey))));
  privateKey = btoa(`-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----`);
  jwks = JSON.stringify({ keys: [{ ...await crypto.subtle.exportKey("jwk", pair.publicKey), kid: "test-key" }] });
});

afterEach(() => vi.unstubAllEnvs());

function setup() {
  vi.stubEnv("CONVEX_SITE_URL", "https://walkies-test.convex.site");
  vi.stubEnv("AUTH_PRIVATE_KEY", privateKey);
  vi.stubEnv("AUTH_JWKS", jwks);
  const t = convexTest(schema, modules);
  registerCore(t);
  registerAnonymousProvider(t);
  return t;
}

describe("simulator test sign-in", () => {
  test.each([undefined, "", "0", "true", "01"])("refuses wrapper and direct anonymous sign-in when flag is %s", async (flag) => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", flag);
    await expect(t.mutation(api.auth.signInForTesting, { name: "Sim A" })).rejects.toThrow("Test sign-in is disabled");
    // A modified client must not bypass the wrapper's gate by using the provider.
    await expect(t.mutation(api.auth.signInAnonymously)).rejects.toThrow("Test sign-in is disabled");
    await expect(t.mutation(internal.users.createUserAnonymous, {
      provider: { name: "anonymous", accountId: "forged", profile: {} },
    })).rejects.toThrow("Test sign-in is disabled");
    expect(await t.run((ctx) => ctx.db.query("users").collect())).toEqual([]);
  });

  test("creates distinct named accounts without emails, usable together in a crew", async () => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", "1");
    const a = await t.mutation(api.auth.signInForTesting, { name: " Sim A " });
    const b = await t.mutation(api.auth.signInForTesting, { name: "Sim B" });
    expect(a.status).toBe("complete");
    expect(a.tokens.accessToken).toBeTruthy();
    expect(a.tokens.refreshToken).toBeTruthy();
    expect(a.tokens.userId).not.toBe(b.tokens.userId);
    const alice = t.withIdentity({ subject: a.tokens.userId });
    const bob = t.withIdentity({ subject: b.tokens.userId });
    expect(await alice.query(api.users.me)).toEqual({ name: "Sim A", email: null });
    expect(await bob.query(api.users.me)).toEqual({ name: "Sim B", email: null });
    const { crewId, inviteCode } = await alice.action(api.crews.createCrew, {
      name: "Simulator crew", colour: "#e67834", sharing: "tiles",
    });
    await bob.action(api.crews.joinCrew, { code: inviteCode, colour: "#467cba", sharing: "tiles" });
    const snapshot = await alice.query(api.crews.crewSnapshot, { crewId });
    expect(snapshot.members.map((m) => m.name).sort()).toEqual(["Sim A", "Sim B"]);
    const rotated = await t.mutation(api.auth.refreshSession, { refreshToken: a.tokens.refreshToken });
    expect(rotated.kind).toBe("rotated");
    if (rotated.kind === "rotated") expect(rotated.tokens.userId).toBe(a.tokens.userId);
  });

  test("unnamed, blank and direct sign-ins get generated names and no email", async () => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", "1");
    const results = [
      await t.mutation(api.auth.signInForTesting, {}),
      await t.mutation(api.auth.signInForTesting, { name: "  " }),
      await t.mutation(api.auth.signInAnonymously),
    ];
    expect(new Set(results.map((r) => r.tokens.userId)).size).toBe(3);
    for (const result of results) {
      const me = await t.withIdentity({ subject: result.tokens.userId }).query(api.users.me);
      expect(me).toEqual({ name: expect.stringMatching(/^Test walker [0-9A-F]{4}$/), email: null });
    }
  });

  test("rejects oversized names before creating an account", async () => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", "1");
    await expect(t.mutation(api.auth.signInForTesting, { name: "A".repeat(81) })).rejects.toThrow("80 characters");
    expect(await t.run((ctx) => ctx.db.query("users").collect())).toEqual([]);
  });
});

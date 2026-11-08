/// <reference types="vite/client" />
import { registerCore } from "@convex-dev/auth/test";
import { registerAnonymousProvider } from "@convex-dev/auth/components/anonymous/test";
import { convexTest } from "convex-test";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import schema from "./schema";
import { guestSignupsPerMinute } from "./users";

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
  test.each([undefined, "", "0", "true", "01"])("refuses the test wrapper when flag is %s", async (flag) => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", flag);
    await expect(t.mutation(api.auth.signInForTesting, { name: "Sim A" })).rejects.toThrow("Test sign-in is disabled");
    expect(await t.run((ctx) => ctx.db.query("users").collect())).toEqual([]);
  });

  test("creates distinct named accounts without emails, usable together in a team", async () => {
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
    expect(await alice.query(api.users.me)).toEqual({ name: "Sim A", email: null, picture: null, guest: false });
    expect(await bob.query(api.users.me)).toEqual({ name: "Sim B", email: null, picture: null, guest: false });
    const { teamId, inviteCode } = await alice.action(api.teams.createTeam, {
      name: "Simulator team", colour: "#e67834",
    });
    await bob.action(api.teams.joinTeam, { code: inviteCode, colour: "#467cba" });
    const snapshot = (await alice.query(api.teams.myTeams)).find((team) => team.teamId === teamId)!;
    expect(snapshot.members.map((m) => m.name).sort()).toEqual(["Sim A", "Sim B"]);
    const rotated = await t.mutation(api.auth.refreshSession, { refreshToken: a.tokens.refreshToken });
    expect(rotated.kind).toBe("rotated");
    if (rotated.kind === "rotated") expect(rotated.tokens.userId).toBe(a.tokens.userId);
  });

  test("unnamed and blank test sign-ins get generated names and no email", async () => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", "1");
    const results = [
      await t.mutation(api.auth.signInForTesting, {}),
      await t.mutation(api.auth.signInForTesting, { name: "  " }),
    ];
    expect(new Set(results.map((r) => r.tokens.userId)).size).toBe(2);
    for (const result of results) {
      const me = await t.withIdentity({ subject: result.tokens.userId }).query(api.users.me);
      expect(me).toEqual({ name: expect.stringMatching(/^Test walker [0-9A-F]{4}$/), email: null, picture: null, guest: false });
    }
  });

  test("rejects oversized names before creating an account", async () => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", "1");
    await expect(t.mutation(api.auth.signInForTesting, { name: "A".repeat(81) })).rejects.toThrow("80 characters");
    expect(await t.run((ctx) => ctx.db.query("users").collect())).toEqual([]);
  });
});

describe("guests", () => {
  // App Store Guideline 5.1.1(v): Walkies has to work without signing up.
  test.each([undefined, "1"])("anyone can start as a guest, test flag %s", async (flag) => {
    const t = setup();
    vi.stubEnv("WALKIES_TEST_SIGNIN", flag);
    const result = await t.mutation(api.auth.signInAnonymously);
    expect(result.status).toBe("complete");
    const me = await t.withIdentity({ subject: result.tokens.userId }).query(api.users.me);
    expect(me).toEqual({ name: expect.stringMatching(/^Walker [0-9A-F]{4}$/), email: null, picture: null, guest: true });
    const rotated = await t.mutation(api.auth.refreshSession, { refreshToken: result.tokens.refreshToken });
    expect(rotated.kind).toBe("rotated");
  });

  test("only so many guests a minute, then more once it's passed", async () => {
    vi.useFakeTimers();
    try {
      const t = setup();
      for (let i = 0; i < guestSignupsPerMinute; i++) await t.mutation(api.auth.signInAnonymously);
      await expect(t.mutation(api.auth.signInAnonymously)).rejects.toThrow("Try again in a minute");
      expect((await t.run((ctx) => ctx.db.query("users").collect())).length).toBe(guestSignupsPerMinute);
      vi.advanceTimersByTime(61_000);
      await t.mutation(api.auth.signInAnonymously);
    } finally {
      vi.useRealTimers();
    }
  });
});

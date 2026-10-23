/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import staticHostingTest from "@convex-dev/static-hosting/test";
import { describe, expect, test } from "vitest";
import schema from "./schema";

// The website and app routes in http.ts. The site itself is uploaded separately
// (`npm run web:upload:prod`), so here nothing has been uploaded yet.

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);

function setup() {
  const t = convexTest(schema, modules);
  staticHostingTest.register(t);
  return t;
}

describe("http routes", () => {
  test("the app's association file and sign-in hand-back still work", async () => {
    const t = setup();
    const aasa = await t.fetch("/.well-known/apple-app-site-association");
    expect(aasa.status).toBe(200);
    expect(aasa.headers.get("Content-Type")).toBe("application/json");
    expect(await aasa.json()).toEqual({ webcredentials: { apps: ["4DTAZSZL6B.com.mikecann.walkies"] } });
    const signedIn = await t.fetch("/app/signed-in?convexAuthCode=abc&state=1", { redirect: "manual" });
    expect(signedIn.status).toBe(302);
    expect(signedIn.headers.get("Location")).toBe("walkies://signed-in?convexAuthCode=abc&state=1");
    const join = await t.fetch("/join/ABCDEFGH");
    expect(await join.text()).toContain("walkies://join/ABCDEFGH");
  });

  test("privacy and help pages are there before the site's uploaded", async () => {
    const t = setup();
    const privacy = await t.fetch("/privacy");
    expect(privacy.status).toBe(200);
    const policy = await privacy.text();
    expect(policy).toContain("Delete account");
    expect(policy).toContain("aws-ap-southeast-2");
    const support = await t.fetch("/support");
    expect(support.status).toBe(200);
    expect(await support.text()).toContain("walkies@mikecann.app");
  });

  test("everything else is static hosting: its setup page for /, a 404 for the rest", async () => {
    const t = setup();
    expect((await t.fetch("/")).status).toBe(503);
    expect((await t.fetch("/no-such-page")).status).toBe(404);
  });
});

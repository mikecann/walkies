/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import feedbackTest from "@convex-dev/feedback/test";
import { expect, test } from "vitest";
import { api, components } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { loreFinished } from "./devices";
import schema from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);

async function setup() {
  const t = convexTest(schema, modules);
  feedbackTest.register(t, "feedback");
  const [mike, dad, other] = await t.run(async (ctx) => [
    await ctx.db.insert("users", { name: "Mike" }),
    await ctx.db.insert("users", { name: "Dad" }),
    await ctx.db.insert("users", { name: "Someone else" }),
  ]);
  await t.run(async (ctx) => {
    await ctx.runMutation(components.feedback.users.setRole, { userId: mike, role: "admin" });
  });
  return { t, mike, dad, other };
}

/** What's been scheduled to go out through APNs. */
async function pushes(t: ReturnType<typeof convexTest>) {
  const jobs = await t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect());
  return jobs.filter((j) => j.name.startsWith("apns")).map((j) => j.args[0] as { userIds: Id<"users">[]; title: string; body: string });
}

test("a phone's token belongs to whoever signed in on it last", async () => {
  const { t, mike, dad } = await setup();
  const device = { deviceId: "phone", platform: "ios", apnsToken: "abc", apnsEnvironment: "production" as const };
  await t.withIdentity({ subject: dad }).mutation(api.devices.register, device);
  await t.withIdentity({ subject: mike }).mutation(api.devices.register, device);
  const rows = await t.run((ctx) => ctx.db.query("devices").collect());
  expect(rows.filter((d) => d.apnsToken === "abc").map((d) => d.userId)).toEqual([mike]);
  await t.withIdentity({ subject: mike }).mutation(api.devices.unregister, { deviceId: "phone" });
  expect((await t.run((ctx) => ctx.db.query("devices").collect())).filter((d) => d.apnsToken)).toEqual([]);
});

test("the admin hears when someone else adds a place, not when they do", async () => {
  const { t, mike, dad } = await setup();
  const file = await t.run((ctx) => ctx.storage.store(new Blob(["{}"])));
  await t.withIdentity({ subject: dad }).mutation(api.sync.savePlace, {
    gridVersion: 2, clientId: "p1", name: "Dunsborough", createdAt: 1, updatedAt: 1, file,
  });
  const file2 = await t.run((ctx) => ctx.storage.store(new Blob(["{}"])));
  await t.withIdentity({ subject: mike }).mutation(api.sync.savePlace, {
    gridVersion: 2, clientId: "p2", name: "Busselton", createdAt: 1, updatedAt: 1, file: file2,
  });
  const sent = (await pushes(t)).filter((p) => p.title === "New place");
  expect(sent).toEqual([expect.objectContaining({ userIds: [mike], body: "Dad added Dunsborough" })]);
});

test("people with the suburb hear about its new secrets, and the admin gets the counts", async () => {
  const { t, mike, dad, other } = await setup();
  await t.run(async (ctx) => {
    const file = await ctx.storage.store(new Blob(["{}"]));
    for (const [userId, osmId] of [[dad, 42], [mike, 42], [other, 7]] as const) {
      await ctx.db.insert("places", { userId, clientId: `p${osmId}`, name: "Porlock", createdAt: 1, updatedAt: 1, file, osmId });
    }
    await loreFinished(ctx, { osmId: 42, name: "Porlock", outcome: "ready", live: 5, pending: 2 });
  });
  expect(await pushes(t)).toEqual([
    expect.objectContaining({ userIds: [dad], body: "5 secrets are hidden in Porlock. Go for a walk to find them." }),
    expect.objectContaining({ userIds: [mike], body: "5 live, 2 waiting for your OK." }),
  ]);
});

test("a run with nothing live, or one that failed, only tells the admin", async () => {
  const { t, mike, dad } = await setup();
  await t.run(async (ctx) => {
    const file = await ctx.storage.store(new Blob(["{}"]));
    await ctx.db.insert("places", { userId: dad, clientId: "p", name: "Porlock", createdAt: 1, updatedAt: 1, file, osmId: 42 });
    await loreFinished(ctx, { osmId: 42, name: "Porlock", outcome: "quiet", live: 0, pending: 1 });
    await loreFinished(ctx, { osmId: 42, name: "Porlock", outcome: "failed", live: 0, pending: 0, error: "Overpass was down" });
  });
  expect((await pushes(t)).map((p) => [p.userIds, p.body])).toEqual([
    [[mike], "Quiet: 0 live, 1 waiting for your OK."],
    [[mike], "Research failed: Overpass was down"],
  ]);
});

/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "./_generated/api";
import schema from "./schema";

const ledger = JSON.stringify({ purchases: [], claims: [], spyglasses: [], equipped: {
  marker: "marker.dot", trail: "trail.teal", clouds: "clouds.classic", cover: "cover.red",
  celebration: "celebration.confetti", updatedAt: 0,
} });
const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);

test("old clients cannot restore local-grid places, walks, secrets or ledgers", async () => {
  const t = convexTest(schema, modules);
  const userId = await t.run((ctx) => ctx.db.insert("users", { name: "Mike" }));
  const client = t.withIdentity({ subject: userId });
  const file = await t.run((ctx) => ctx.storage.store(new Blob(["raw GPS"])));
  const calls = [
    [api.sync.savePlace, { clientId: "place", name: "Home", createdAt: 1, updatedAt: 1, file }],
    [api.sync.deletePlace, { clientId: "place" }],
    [api.sync.saveWalk, { clientId: "walk", startedAt: 1, endedAt: 2, distance: 10, newTiles: 1, file }],
    [api.sync.saveSecrets, { secrets: [{ secretId: "secret", foundAt: 1 }] }],
    [api.sync.saveProgress, { ledger }],
  ] as const;
  for (const [fn, args] of calls) {
    // These deliberately bypass the TS contract to exercise runtime validation.
    await expect(client.mutation(fn, args as never)).rejects.toThrow();
    await expect(client.mutation(fn, { ...args, gridVersion: 1 } as never)).rejects.toThrow();
  }
  expect((await client.query(api.sync.snapshot, {})).places).toEqual([]);
  await client.mutation(api.sync.savePlace, { ...calls[0][1], gridVersion: 2 });
  await client.mutation(api.sync.saveSecrets, { secrets: [...calls[3][1].secrets], gridVersion: 2 });
  await client.mutation(api.sync.saveProgress, { ledger, gridVersion: 2 });
  const snapshot = await client.query(api.sync.snapshot, {});
  expect(snapshot.places).toHaveLength(1);
  expect(snapshot.secrets).toHaveLength(1);
  expect(snapshot.progress).not.toBeNull();
});

test("world clients replace old walk blobs while keeping the walk identity and raw GPS", async () => {
  const t = convexTest(schema, modules);
  const userId = await t.run((ctx) => ctx.db.insert("users", { name: "Mike" }));
  const client = t.withIdentity({ subject: userId });
  const oldFile = await t.run((ctx) => ctx.storage.store(new Blob(["old coverage, same GPS"])));
  await t.run((ctx) => ctx.db.insert("walks", {
    userId, clientId: "walk", startedAt: 1, endedAt: 2, distance: 10, newTiles: 99, file: oldFile,
  }));
  const file = await t.run((ctx) => ctx.storage.store(new Blob(["world coverage, same GPS"])));
  await client.mutation(api.sync.saveWalk, {
    gridVersion: 2, clientId: "walk", startedAt: 1, endedAt: 2, distance: 10, newTiles: 2, file,
  });
  const rows = await t.run((ctx) => ctx.db.query("walks").collect());
  expect(rows).toHaveLength(1);
  expect(rows[0]).toMatchObject({ clientId: "walk", newTiles: 2, file });
  expect(await t.run((ctx) => ctx.storage.get(oldFile))).toBeNull();
});

test("walk links can be left out of the snapshot and asked for just for missing walks", async () => {
  const t = convexTest(schema, modules);
  const userId = await t.run((ctx) => ctx.db.insert("users", { name: "Mike" }));
  const client = t.withIdentity({ subject: userId });
  const otherId = await t.run((ctx) => ctx.db.insert("users", { name: "Seth" }));
  // Each walk its own upload, as the phones do it.
  const upload = () => t.run((ctx) => ctx.storage.store(new Blob(["raw GPS"])));
  for (const clientId of ["a", "b"]) {
    await client.mutation(api.sync.saveWalk, { clientId, startedAt: 1, endedAt: 2, distance: 10, newTiles: 1, file: await upload(), gridVersion: 2 });
  }
  await t.withIdentity({ subject: otherId }).mutation(api.sync.saveWalk, { clientId: "theirs", startedAt: 1, endedAt: 2, distance: 10, newTiles: 1, file: await upload(), gridVersion: 2 });
  // Older phones still get every link.
  expect((await client.query(api.sync.snapshot, {})).walks.every((w) => w.url !== null)).toBe(true);
  const lean = await client.query(api.sync.snapshot, { walkUrls: false });
  expect(lean.walks.map((w) => [w.clientId, w.url]).sort()).toEqual([["a", null], ["b", null]]);
  const links = await client.query(api.sync.walkUrls, { clientIds: ["b", "b", "theirs", "nope"] });
  expect(links.map((w) => w.clientId)).toEqual(["b"]);
  expect(links[0].url).toBeTruthy();
});

test("a save can't take over a file something else uses, so it can't be deleted", async () => {
  const t = convexTest(schema, modules);
  const userId = await t.run((ctx) => ctx.db.insert("users", { name: "Guest", guest: true }));
  const client = t.withIdentity({ subject: userId });
  // A shared street file, as places:get hands out, and someone else's walk.
  const streets = await t.run((ctx) => ctx.storage.store(new Blob(["streets"])));
  await t.run((ctx) => ctx.db.insert("placeData", { osmId: 1, name: "Fremantle", fetchedAt: 1, version: 2, file: streets }));
  const otherId = await t.run((ctx) => ctx.db.insert("users", { name: "Other" }));
  const theirs = await t.run((ctx) => ctx.storage.store(new Blob(["their GPS"])));
  await t.run((ctx) => ctx.db.insert("walks", { userId: otherId, clientId: "w", startedAt: 1, endedAt: 2, distance: 1, newTiles: 0, file: theirs }));
  for (const file of [streets, theirs]) {
    const place = { gridVersion: 2 as const, clientId: "p", name: "Mine", createdAt: 1, updatedAt: 1, file };
    await expect(client.mutation(api.sync.savePlace, place)).rejects.toThrow("already in use");
    await expect(client.mutation(api.sync.saveWalk, { gridVersion: 2, clientId: "w", startedAt: 1, endedAt: 2, distance: 1, newTiles: 0, file })).rejects.toThrow("already in use");
  }
  // Its own fresh upload is fine, and saving the same file again doesn't delete it.
  const mine = await t.run((ctx) => ctx.storage.store(new Blob(["my place"])));
  const place = { gridVersion: 2 as const, clientId: "p", name: "Mine", createdAt: 1, updatedAt: 1, file: mine };
  await client.mutation(api.sync.savePlace, place);
  await client.mutation(api.sync.savePlace, place);
  await client.mutation(api.sync.savePlace, { ...place, updatedAt: 2 });
  expect(await t.run((ctx) => ctx.storage.getUrl(mine))).not.toBeNull();
  expect(await t.run((ctx) => ctx.storage.getUrl(streets))).not.toBeNull();
  expect(await t.run((ctx) => ctx.storage.getUrl(theirs))).not.toBeNull();
});

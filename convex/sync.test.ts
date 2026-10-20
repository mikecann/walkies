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
  expect((await client.query(api.sync.snapshot)).places).toEqual([]);
  await client.mutation(api.sync.savePlace, { ...calls[0][1], gridVersion: 2 });
  await client.mutation(api.sync.saveSecrets, { secrets: [...calls[3][1].secrets], gridVersion: 2 });
  await client.mutation(api.sync.saveProgress, { ledger, gridVersion: 2 });
  const snapshot = await client.query(api.sync.snapshot);
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

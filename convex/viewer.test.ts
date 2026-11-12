/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import feedbackTest from "@convex-dev/feedback/test";
import { register } from "@convex-dev/state-machines/test";
import { describe, expect, test } from "vitest";
import { api, components } from "./_generated/api";
import schema from "./schema";
import * as viewerModule from "./viewer";

// The state machines viewer's queries (viewer.ts), behind the admin page: only Chef's admin
// reads anything. Everyone else gets null from every one of them, which the viewer shows
// as "off", rather than an error.

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);
type T = ReturnType<typeof convexTest>;
type Caller = T | ReturnType<T["withIdentity"]>;

function setup() {
  const t = convexTest(schema, modules);
  feedbackTest.register(t);
  register(t);
  return t;
}

const everyQuery = (caller: Caller) =>
  Promise.all([
    caller.query(api.viewer.overview, {}),
    caller.query(api.viewer.counts, { machine: "loreEntry" }),
    caller.query(api.viewer.rows, { table: "loreEntries" }),
    caller.query(api.viewer.row, { table: "lorePlaces", id: "nothing" }),
  ]);
const nothing = [null, null, null, null];

describe("the machines viewer", () => {
  test("answers null when nobody's signed in", async () => {
    expect(await everyQuery(setup())).toEqual(nothing);
  });

  test("answers null to someone signed in, a guest, and a Chef member", async () => {
    const t = setup();
    const [walker, guest, member] = await t.run((ctx) => Promise.all([
      ctx.db.insert("users", { name: "Walker", email: "walker@example.com", emailVerified: true }),
      ctx.db.insert("users", { guest: true }),
      ctx.db.insert("users", { name: "Member" }),
    ]));
    await t.run((ctx) => ctx.runMutation(components.feedback.users.setRole, { userId: member, role: "member" }));
    for (const userId of [walker, guest, member]) {
      expect(await everyQuery(t.withIdentity({ subject: userId }))).toEqual(nothing);
    }
  });

  test("answers null to an admin's account once it's deleted", async () => {
    const t = setup();
    const admin = await t.run((ctx) => ctx.db.insert("users", { name: "Mike" }));
    await t.run(async (ctx) => {
      await ctx.runMutation(components.feedback.users.setRole, { userId: admin, role: "admin" });
      await ctx.db.patch("users", admin, { deletedAt: Date.now() });
    });
    expect(await everyQuery(t.withIdentity({ subject: admin }))).toEqual(nothing);
  });

  test("shows Chef's admin the machines, through an account merged into theirs too, and nothing can send", async () => {
    const t = setup();
    const [admin, older] = await t.run((ctx) => Promise.all([
      ctx.db.insert("users", { name: "Mike" }),
      ctx.db.insert("users", { name: "Mike's Google" }),
    ]));
    await t.run(async (ctx) => {
      await ctx.runMutation(components.feedback.users.setRole, { userId: admin, role: "admin" });
      await ctx.db.patch("users", older, { mergedInto: admin });
    });
    for (const subject of [admin, older]) {
      const asAdmin = t.withIdentity({ subject });
      const overview = await asAdmin.query(api.viewer.overview, {});
      expect(overview?.send).toBe(false);
      expect(overview?.machines.map((machine) => machine.name)).toEqual(["lorePlace", "loreEntry"]);
      const counts = await asAdmin.query(api.viewer.counts, { machine: "loreEntry" });
      expect(counts?.counts).toEqual(expect.objectContaining({ checking: 0, pending: 0 }));
      expect((await asAdmin.query(api.viewer.rows, { table: "loreEntries" }))?.rows).toEqual([]);
    }
    // The module has no send or create to call.
    expect(Object.keys(viewerModule).sort()).toEqual(["counts", "overview", "row", "rows"]);
  });
});

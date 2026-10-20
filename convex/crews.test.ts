/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { api } from "./_generated/api";
import schema from "./schema";

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);

async function setup() {
  const t = convexTest(schema, modules);
  const [aliceId, bobId, outsiderId] = await t.run(async (ctx) => Promise.all([
    ctx.db.insert("users", { name: "Alice" }),
    ctx.db.insert("users", { name: "Bob" }),
    ctx.db.insert("users", { name: "Eve" }),
  ]));
  // Convex Auth v2 uses the user id as the identity subject. This exercises the
  // real currentUserId helper, including merged accounts, without OAuth setup.
  const alice = t.withIdentity({ subject: aliceId });
  const bob = t.withIdentity({ subject: bobId });
  const outsider = t.withIdentity({ subject: outsiderId });
  const { crewId, inviteCode } = await alice.mutation(api.crews.createCrew, {
    name: "Alice & Bob", colour: "#e67834", sharing: "tilesAndTrail",
  });
  const file = () => t.run((ctx) => ctx.storage.store(new Blob(['{"crew":"test"}'], { type: "application/json" })));
  const addPlace = async (clientId = "suburb") => alice.mutation(api.crews.addCrewPlace, {
    crewId, clientId, name: "Our suburb", file: await file(),
  });
  const joinBob = () => bob.mutation(api.crews.joinCrew, { code: inviteCode, colour: "#467cba", sharing: "tilesAndTrail", name: "Dad" });
  return { t, alice, bob, outsider, aliceId, bobId, crewId, inviteCode, file, addPlace, joinBob };
}

afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

describe("crew maps", () => {
  test("create, join, update preferences and leave; duplicate joins preserve membership", async () => {
    const { alice, bob, crewId, inviteCode, joinBob } = await setup();
    expect(await alice.query(api.crews.myCrews)).toMatchObject([{
      crewId, name: "Alice & Bob", memberCount: 1,
      membership: { name: "Alice", sharing: "tilesAndTrail", walksCount: true, isYou: true },
    }]);
    expect(await joinBob()).toBe(crewId);
    expect(await bob.mutation(api.crews.joinCrew, { code: inviteCode, colour: "ignored", sharing: "tiles", name: "ignored" })).toBe(crewId);
    let snapshot = await alice.query(api.crews.crewSnapshot, { crewId });
    expect(snapshot.members).toHaveLength(2);
    expect(snapshot.members.find((m) => !m.isYou)).toMatchObject({ name: "Dad", colour: "#467cba", sharing: "tilesAndTrail" });
    await bob.mutation(api.crews.updateMembership, { crewId, colour: "purple", walksCount: false });
    snapshot = await bob.query(api.crews.crewSnapshot, { crewId });
    expect(snapshot.members.find((m) => m.isYou)).toMatchObject({ colour: "purple", walksCount: false });
    await bob.mutation(api.crews.leaveCrew, { crewId });
    expect(await bob.query(api.crews.myCrews)).toEqual([]);
    expect((await alice.query(api.crews.myCrews))[0].memberCount).toBe(1);
  });

  test("all public functions require sign-in", async () => {
    const { t, crewId, inviteCode, addPlace, file, bobId } = await setup();
    const placeId = await addPlace();
    const upload = await file();
    await expect(t.query(api.crews.myCrews)).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.query(api.crews.crewForInvite, { code: inviteCode })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.query(api.crews.crewSnapshot, { crewId })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.mutation(api.crews.createCrew, { name: "x", colour: "red", sharing: "tiles" })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.mutation(api.crews.joinCrew, { code: inviteCode, colour: "red", sharing: "tiles" })).rejects.toThrow("UNAUTHENTICATED");
    const writes = [
      t.mutation(api.crews.updateMembership, { crewId, sharing: "tiles" }),
      t.mutation(api.crews.leaveCrew, { crewId }),
      t.mutation(api.crews.renameCrew, { crewId, name: "x" }),
      t.mutation(api.crews.removeMember, { crewId, userId: bobId }),
      t.mutation(api.crews.addCrewPlace, { crewId, clientId: "x", name: "x", file: upload }),
      t.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes: [[0, 0]], at: 1 }),
      t.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "x", file: upload }),
      t.mutation(api.crews.recordCrewSecrets, { crewId, secrets: [{ secretId: "x", at: 1 }] }),
    ];
    await Promise.all(writes.map((write) => expect(write).rejects.toThrow("UNAUTHENTICATED")));
  });

  test("non-members cannot read snapshots or write any crew data", async () => {
    const { outsider, crewId, aliceId, file, addPlace } = await setup();
    const placeId = await addPlace();
    const upload = await file();
    await expect(outsider.query(api.crews.crewSnapshot, { crewId })).rejects.toThrow("NOT_A_MEMBER");
    const writes = [
      outsider.mutation(api.crews.updateMembership, { crewId, colour: "x" }),
      outsider.mutation(api.crews.leaveCrew, { crewId }),
      outsider.mutation(api.crews.renameCrew, { crewId, name: "x" }),
      outsider.mutation(api.crews.removeMember, { crewId, userId: aliceId }),
      outsider.mutation(api.crews.addCrewPlace, { crewId, clientId: "x", name: "x", file: upload }),
      outsider.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes: [[0, 0]], at: 1 }),
      outsider.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "x", file: upload }),
      outsider.mutation(api.crews.recordCrewSecrets, { crewId, secrets: [{ secretId: "x", at: 1 }] }),
    ];
    await Promise.all(writes.map((write) => expect(write).rejects.toThrow("NOT_A_MEMBER")));
    expect(await outsider.query(api.crews.myCrews)).toEqual([]);
  });

  test("invite preview normalizes codes, lists names, and returns null for unknown codes", async () => {
    const { alice, bob, outsider, crewId, inviteCode, joinBob } = await setup();
    expect(inviteCode).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$/);
    await joinBob();
    expect(await outsider.query(api.crews.crewForInvite, { code: ` ${inviteCode.toLowerCase()} ` })).toEqual({ name: "Alice & Bob", memberNames: ["Alice", "Dad"] });
    expect(await alice.query(api.crews.crewForInvite, { code: "INVALID" })).toBeNull();
    expect(await alice.query(api.crews.crewForInvite, { code: "222222" })).toBeNull();
    await expect(bob.mutation(api.crews.joinCrew, { code: "bad", colour: "red", sharing: "tiles" })).rejects.toThrow("INVALID_INVITE");
    expect((await bob.query(api.crews.myCrews))[0].crewId).toBe(crewId);
  });

  test("invite collisions are retried and crews get distinct codes", async () => {
    const { alice, inviteCode } = await setup();
    const alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
    const random = vi.spyOn(Math, "random");
    for (const character of inviteCode) random.mockReturnValueOnce((alphabet.indexOf(character) + 0.1) / alphabet.length);
    const nextCharacter = inviteCode[0] === "A" ? "B" : "A";
    random.mockReturnValue((alphabet.indexOf(nextCharacter) + 0.1) / alphabet.length);
    const second = await alice.mutation(api.crews.createCrew, { name: "Another crew", colour: "blue", sharing: "tiles" });
    expect(second.inviteCode).not.toBe(inviteCode);
    expect(second.inviteCode).toBe(nextCharacter.repeat(6));
    expect(random).toHaveBeenCalledTimes(12);
    expect((await alice.query(api.crews.myCrews))).toHaveLength(2);
  });

  test("only the creator can rename or remove; removal erases trails but keeps credits", async () => {
    const { alice, bob, crewId, bobId, file, joinBob, addPlace, t } = await setup();
    await joinBob();
    const placeId = await addPlace();
    const trail = await file();
    await bob.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "walk", file: trail });
    await bob.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes: [[1, 2]], at: 12 });
    await bob.mutation(api.crews.recordCrewSecrets, { crewId, secrets: [{ secretId: "history", at: 12 }] });
    await expect(bob.mutation(api.crews.renameCrew, { crewId, name: "Oops" })).rejects.toThrow("CREATOR_ONLY");
    await expect(bob.mutation(api.crews.removeMember, { crewId, userId: bobId })).rejects.toThrow("CREATOR_ONLY");
    await alice.mutation(api.crews.renameCrew, { crewId, name: "Family" });
    await alice.mutation(api.crews.removeMember, { crewId, userId: bobId });
    await alice.mutation(api.crews.removeMember, { crewId, userId: bobId });
    const snapshot = await alice.query(api.crews.crewSnapshot, { crewId });
    expect(snapshot.crew.name).toBe("Family");
    expect(snapshot.members).toHaveLength(1);
    expect(snapshot.trails).toEqual([]);
    expect(snapshot.tiles[0].by).toBe(bobId);
    expect(snapshot.secrets[0].by).toBe(bobId);
    expect(await t.run((ctx) => ctx.storage.getUrl(trail))).toBeNull();
    await expect(bob.query(api.crews.crewSnapshot, { crewId })).rejects.toThrow("NOT_A_MEMBER");
  });

  test("places are idempotent and tiles are batched, first-wins and retry safe", async () => {
    const { alice, bob, aliceId, crewId, addPlace, file, joinBob } = await setup();
    await joinBob();
    const placeId = await addPlace();
    expect(await bob.mutation(api.crews.addCrewPlace, { crewId, clientId: "suburb", name: "Ignored", file: await file() })).toBe(placeId);
    const hexes = Array.from({ length: 500 }, (_, q) => [q, -q]);
    expect(await alice.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes: [...hexes, [0, 0]], at: 100 })).toBe(500);
    expect(await alice.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes, at: 100 })).toBe(0);
    expect(await bob.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes, at: 1 })).toBe(0);
    const snapshot = await bob.query(api.crews.crewSnapshot, { crewId });
    expect(snapshot.tiles).toHaveLength(500);
    expect(snapshot.tiles.every((t) => t.by === aliceId && t.at === 100)).toBe(true);
    expect(snapshot.places).toMatchObject([{ placeId, clientId: "suburb", name: "Our suburb", url: expect.any(String) }]);
  });

  test("tile uploads reject foreign places, malformed hexes and excessive batches", async () => {
    const { alice, crewId, addPlace } = await setup();
    const placeId = await addPlace();
    for (const hexes of [[[1]], [[1, 2, 3]], [[1.5, 2]], [[NaN, 2]], Array.from({ length: 1001 }, () => [0, 0])]) {
      await expect(alice.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes, at: 1 })).rejects.toThrow("INVALID_ARGUMENT");
    }
    const second = await alice.mutation(api.crews.createCrew, { name: "Second", colour: "green", sharing: "tiles" });
    await expect(alice.mutation(api.crews.uploadCrewTiles, { crewId: second.crewId, placeId, hexes: [[0, 0]], at: 1 })).rejects.toThrow("PLACE_NOT_FOUND");
    expect((await alice.query(api.crews.crewSnapshot, { crewId })).tiles).toEqual([]);
  });

  test("trail replacement is per member and opt-out deletes files; re-enabling does not resurrect them", async () => {
    const { alice, bob, t, crewId, file, joinBob } = await setup();
    await joinBob();
    const oldFile = await file();
    const newFile = await file();
    const bobFile = await file();
    await alice.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "same-walk", file: oldFile });
    await alice.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "same-walk", file: oldFile });
    await bob.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "same-walk", file: bobFile });
    await alice.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "same-walk", file: newFile });
    expect(await t.run((ctx) => ctx.storage.getUrl(oldFile))).toBeNull();
    expect((await bob.query(api.crews.crewSnapshot, { crewId })).trails).toHaveLength(2);
    await alice.mutation(api.crews.updateMembership, { crewId, sharing: "tiles" });
    expect((await bob.query(api.crews.crewSnapshot, { crewId })).trails).toHaveLength(1);
    expect(await t.run((ctx) => ctx.storage.getUrl(newFile))).toBeNull();
    await expect(alice.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "x", file: await file() })).rejects.toThrow("TRAIL_SHARING_DISABLED");
    await alice.mutation(api.crews.updateMembership, { crewId, sharing: "tilesAndTrail" });
    expect((await bob.query(api.crews.crewSnapshot, { crewId })).trails).toHaveLength(1);
  });

  test("snapshot also hides stale trails from non-sharing or departed members", async () => {
    const { alice, bob, t, aliceId, crewId, file, joinBob } = await setup();
    await joinBob();
    const stored = await file();
    await t.run(async (ctx) => {
      const member = await ctx.db.query("crewMembers").withIndex("by_crew_user", (q) => q.eq("crewId", crewId).eq("userId", aliceId)).unique();
      await ctx.db.patch("crewMembers", member!._id, { sharing: "tiles" });
      await ctx.db.insert("crewTrails", { crewId, userId: aliceId, walkClientId: "stale", file: stored, at: 1 });
    });
    expect((await bob.query(api.crews.crewSnapshot, { crewId })).trails).toEqual([]);
    await alice.mutation(api.crews.leaveCrew, { crewId });
    expect((await bob.query(api.crews.crewSnapshot, { crewId })).trails).toEqual([]);
  });

  test("secrets retain the first finder and timestamp through duplicate and older replays", async () => {
    const { alice, bob, aliceId, bobId, crewId, joinBob } = await setup();
    await joinBob();
    await alice.mutation(api.crews.recordCrewSecrets, { crewId, secrets: [{ secretId: "heritage", at: 100 }, { secretId: "heritage", at: 90 }] });
    await bob.mutation(api.crews.recordCrewSecrets, { crewId, secrets: [{ secretId: "heritage", at: 1 }, { secretId: "nature", at: 50 }] });
    expect((await alice.query(api.crews.crewSnapshot, { crewId })).secrets).toEqual([
      { secretId: "heritage", by: aliceId, at: 100 }, { secretId: "nature", by: bobId, at: 50 },
    ]);
    await bob.mutation(api.crews.leaveCrew, { crewId });
    expect((await alice.query(api.crews.crewSnapshot, { crewId })).secrets).toHaveLength(2);
  });

  test("since uses ingestion time, handles same-millisecond uploads, and filters only tiles", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-20T00:00:00Z"));
    const { alice, crewId, addPlace, file } = await setup();
    const placeId = await addPlace();
    const initial = await alice.query(api.crews.crewSnapshot, { crewId });
    await alice.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes: [[1, 2]], at: 100 });
    const first = await alice.query(api.crews.crewSnapshot, { crewId, since: initial.serverTime });
    expect(first.tiles).toHaveLength(1);
    expect(first.serverTime).toBeGreaterThan(initial.serverTime);
    await alice.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes: [[2, 3]], at: 1 });
    await alice.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "walk", file: await file() });
    await alice.mutation(api.crews.recordCrewSecrets, { crewId, secrets: [{ secretId: "old", at: 1 }] });
    const next = await alice.query(api.crews.crewSnapshot, { crewId, since: first.serverTime });
    expect(next.tiles).toMatchObject([{ q: 2, r: 3, at: 1 }]);
    expect(next.serverTime).toBeGreaterThan(first.serverTime);
    expect(next.members).toHaveLength(1);
    expect(next.places).toHaveLength(1);
    expect(next.trails).toHaveLength(1);
    expect(next.secrets).toHaveLength(1);
    expect((await alice.query(api.crews.crewSnapshot, { crewId, since: next.serverTime })).tiles).toEqual([]);
    expect((await alice.query(api.crews.crewSnapshot, { crewId })).tiles).toHaveLength(2);
  });

  test("the last departure deletes every crew row and owned file, leaving personal data intact", async () => {
    const { t, alice, bob, aliceId, crewId, file, addPlace, joinBob, inviteCode } = await setup();
    await joinBob();
    const placeId = await addPlace();
    const trail = await file();
    const personalFile = await file();
    await t.run((ctx) => ctx.db.insert("walks", { userId: aliceId, clientId: "personal", startedAt: 1, endedAt: 2, distance: 1, newTiles: 1, file: personalFile }));
    await alice.mutation(api.crews.uploadCrewTrail, { crewId, walkClientId: "walk", file: trail });
    await alice.mutation(api.crews.uploadCrewTiles, { crewId, placeId, hexes: [[1, 2]], at: 1 });
    await alice.mutation(api.crews.recordCrewSecrets, { crewId, secrets: [{ secretId: "secret", at: 1 }] });
    const placeFile = await t.run(async (ctx) => (await ctx.db.get("crewPlaces", placeId))!.file);
    await alice.mutation(api.crews.leaveCrew, { crewId });
    expect((await bob.query(api.crews.crewSnapshot, { crewId })).tiles).toHaveLength(1);
    expect(await t.run((ctx) => ctx.storage.getUrl(trail))).toBeNull();
    await bob.mutation(api.crews.leaveCrew, { crewId });
    for (const table of ["crews", "crewMembers", "crewPlaces", "crewTiles", "crewTrails", "crewSecrets"] as const) {
      expect(await t.run((ctx) => ctx.db.query(table).collect())).toEqual([]);
    }
    expect(await t.run((ctx) => ctx.storage.getUrl(placeFile))).toBeNull();
    expect(await t.run((ctx) => ctx.storage.getUrl(personalFile))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("walks").collect())).toHaveLength(1);
    expect(await alice.query(api.crews.crewForInvite, { code: inviteCode })).toBeNull();
  });

  test("merged identities use the canonical user's membership", async () => {
    const { t, aliceId, crewId } = await setup();
    const duplicateId = await t.run((ctx) => ctx.db.insert("users", { name: "Duplicate", mergedInto: aliceId }));
    const duplicate = t.withIdentity({ subject: duplicateId });
    const snapshot = await duplicate.query(api.crews.crewSnapshot, { crewId });
    expect(snapshot.members).toMatchObject([{ userId: aliceId, isYou: true }]);
    await duplicate.mutation(api.crews.renameCrew, { crewId, name: "Canonical" });
    expect((await duplicate.query(api.crews.myCrews))[0].name).toBe("Canonical");
  });

  test("large empty maps finish cleanup in scheduled batches without affecting another crew", async () => {
    vi.useFakeTimers();
    const { t, alice, crewId, addPlace, inviteCode } = await setup();
    const placeId = await addPlace();
    const other = await alice.mutation(api.crews.createCrew, { name: "Keep me", colour: "blue", sharing: "tiles" });
    await t.run(async (ctx) => {
      for (let q = 0; q < 1001; q++) {
        const crew = await ctx.db.get("crews", crewId);
        await ctx.db.insert("crewTiles", { crewId, placeId, q, r: 0, by: crew!.createdBy, at: 1, receivedAt: 1 });
      }
    });
    await alice.mutation(api.crews.leaveCrew, { crewId });
    expect(await alice.query(api.crews.crewForInvite, { code: inviteCode })).toBeNull();
    await expect(alice.query(api.crews.crewSnapshot, { crewId })).rejects.toThrow("NOT_A_MEMBER");
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run((ctx) => ctx.db.query("crewTiles").collect())).toEqual([]);
    expect((await alice.query(api.crews.myCrews)).map((crew) => crew.crewId)).toEqual([other.crewId]);
  });

  test("join HTML opens Walkies, escapes names and handles unknown invites without leaking members", async () => {
    const { t, alice, crewId, inviteCode } = await setup();
    await alice.mutation(api.crews.renameCrew, { crewId, name: '<script>alert("x")</script> & crew' });
    const response = await t.fetch(`/join/${inviteCode.toLowerCase()}`);
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("text/html");
    const html = await response.text();
    expect(html).toContain(`walkies://join/${inviteCode}`);
    expect(html).toContain("window.location.href");
    expect(html).toContain("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; crew");
    expect(html).not.toContain("Alice");
    const unknown = await t.fetch("/join/bad-code");
    expect(unknown.status).toBe(404);
    expect(await unknown.text()).toContain("Ask someone in the crew");
  });
});

/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
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
  const { teamId, inviteCode } = await alice.action(api.teams.createTeam, {
    name: "Alice & Bob", colour: "#e67834", sharing: "tilesAndTrail",
  });
  const file = (owner = alice) => owner.action(api.teams.uploadFile, { json: '{"team":"test"}' });
  const addPlace = async (clientId = "suburb") => alice.action(api.teams.addTeamPlace, { bounds: { minQ: -1000, maxQ: 1000, minR: -1000, maxR: 1000 },
    teamId, clientId, name: "Our suburb", file: await file(),
  });
  const joinBob = () => bob.action(api.teams.joinTeam, { code: inviteCode, colour: "#467cba", sharing: "tilesAndTrail", name: "Dad" });
  return { t, alice, bob, outsider, aliceId, bobId, teamId, inviteCode, file, addPlace, joinBob };
}

afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

describe("team maps", () => {
  test("create, join, update preferences and leave; duplicate joins preserve membership", async () => {
    const { alice, bob, teamId, inviteCode, joinBob } = await setup();
    expect(await alice.query(api.teams.myTeams)).toMatchObject([{
      teamId, name: "Alice & Bob", memberCount: 1,
      membership: { name: "Alice", sharing: "tilesAndTrail", walksCount: true, isYou: true },
    }]);
    expect(await joinBob()).toBe(teamId);
    expect(await bob.action(api.teams.joinTeam, { code: inviteCode, colour: "ignored", sharing: "tiles", name: "ignored" })).toBe(teamId);
    let snapshot = await alice.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.members).toHaveLength(2);
    expect(snapshot.members.find((m) => !m.isYou)).toMatchObject({ name: "Dad", colour: "#467cba", sharing: "tilesAndTrail" });
    await bob.mutation(api.teams.updateMembership, { teamId, colour: "purple", walksCount: false });
    snapshot = await bob.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.members.find((m) => m.isYou)).toMatchObject({ colour: "purple", walksCount: false });
    await bob.mutation(api.teams.leaveTeam, { teamId });
    expect(await bob.query(api.teams.myTeams)).toEqual([]);
    expect((await alice.query(api.teams.myTeams))[0].memberCount).toBe(1);
  });

  test("members see each other's photos; me returns your own", async () => {
    const { t, alice, bob, outsider, aliceId, bobId, teamId, joinBob } = await setup();
    await t.run((ctx) => ctx.db.patch("users", aliceId, { picture: "https://lh3.googleusercontent.com/alice" }));
    expect(await alice.query(api.users.me)).toEqual({ name: "Alice", email: null, picture: "https://lh3.googleusercontent.com/alice" });
    expect(await bob.query(api.users.me)).toMatchObject({ picture: null });
    expect((await alice.query(api.teams.myTeams))[0].membership.picture).toBe("https://lh3.googleusercontent.com/alice");
    await joinBob();
    const snapshot = await bob.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.members.find((m) => m.userId === aliceId)?.picture).toBe("https://lh3.googleusercontent.com/alice");
    expect(snapshot.members.find((m) => m.userId === bobId)?.picture).toBeNull();
    await expect(outsider.query(api.teams.teamSnapshot, { teamId })).rejects.toThrow("NOT_A_MEMBER");
  });

  test("competing first-place adds must retry on the winning grid; lost replies stay idempotent", async () => {
    const { alice, bob, teamId, joinBob, file } = await setup();
    await joinBob();
    const bounds = { minQ: -5, maxQ: 5, minR: -5, maxR: 5 };
    const a = { teamId, clientId: "a", name: "First", bounds, gridPlaceId: null, file: await file() };
    const b = { teamId, clientId: "b", name: "Second", bounds, gridPlaceId: null, file: await file(bob) };
    const results = await Promise.allSettled([
      alice.action(api.teams.addTeamPlace, a), bob.action(api.teams.addTeamPlace, b),
    ]);
    expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    const failed = results.find((r) => r.status === "rejected") as PromiseRejectedResult;
    expect(String(failed.reason)).toContain("GRID_CHANGED");
    const snapshot = await alice.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.places).toHaveLength(1);
    const winner = snapshot.places[0];
    const [owner, args, loser, rejected] = winner.clientId === "a" ? [alice, a, bob, b] : [bob, b, alice, a];
    // Same client ID is accepted before the stale null anchor is checked.
    expect(await owner.action(api.teams.addTeamPlace, args)).toBe(winner.placeId);
    expect(await loser.run((ctx) => ctx.storage.getUrl(rejected.file))).toBeNull();
    const saved = await loser.action(api.teams.addTeamPlace, { ...rejected, file: await file(loser), gridPlaceId: winner.placeId });
    expect(saved).not.toBe(winner.placeId);
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).places).toHaveLength(2);
  });

  test("packed history batches retain per-tile discovery dates and validate their lengths", async () => {
    const { alice, teamId, addPlace } = await setup();
    const placeId = await addPlace();
    await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[0, 0], [1, 0]], at: 10, discoveredAt: [10, 20] });
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).tiles.map(({ q, at }) => ({ q, at }))).toEqual([{ q: 0, at: 10 }, { q: 1, at: 20 }]);
    await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[2, 0]], at: 1, discoveredAt: [] })).rejects.toThrow("INVALID_ARGUMENT");
    await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[2, 0]], at: 1, discoveredAt: [Infinity] })).rejects.toThrow("INVALID_ARGUMENT");
  });

  test("paused members cannot contribute tiles, secrets or trails, including queued retries", async () => {
    const { alice, teamId, addPlace, file } = await setup();
    const placeId = await addPlace();
    const queued = await file();
    await alice.mutation(api.teams.updateMembership, { teamId, walksCount: false });
    await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[0, 0]], at: 1 })).rejects.toThrow("CONTRIBUTIONS_PAUSED");
    await expect(alice.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "secret", at: 1 }] })).rejects.toThrow("CONTRIBUTIONS_PAUSED");
    await expect(alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "queued", updatedAt: 1, file: queued })).rejects.toThrow("CONTRIBUTIONS_PAUSED");
    const snapshot = await alice.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.tiles).toEqual([]);
    expect(snapshot.secrets).toEqual([]);
    expect(snapshot.trails).toEqual([]);
    expect(await alice.run((ctx) => ctx.storage.getUrl(queued))).toBeNull();
    await alice.mutation(api.teams.updateMembership, { teamId, walksCount: true });
    expect(await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[0, 0]], at: 2 })).toBe(1);
  });

  test("all public functions require sign-in", async () => {
    const { t, teamId, inviteCode, addPlace, file, bobId } = await setup();
    const placeId = await addPlace();
    const upload = await file();
    await expect(t.query(api.teams.myTeams)).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.mutation(api.teams.teamForInvite, { code: inviteCode })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.query(api.teams.teamSnapshot, { teamId })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.action(api.teams.createTeam, { name: "x", colour: "red", sharing: "tiles" })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.action(api.teams.joinTeam, { code: inviteCode, colour: "red", sharing: "tiles" })).rejects.toThrow("UNAUTHENTICATED");
    const writes = [
      t.mutation(api.teams.updateMembership, { teamId, sharing: "tiles" }),
      t.mutation(api.teams.leaveTeam, { teamId }),
      t.mutation(api.teams.renameTeam, { teamId, name: "x" }),
      t.action(api.teams.removeMember, { teamId, userId: bobId }),
      t.action(api.teams.addTeamPlace, { bounds: { minQ: -1000, maxQ: 1000, minR: -1000, maxR: 1000 }, teamId, clientId: "x", name: "x", file: upload }),
      t.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[0, 0]], at: 1 }),
      t.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "x", file: upload }),
      t.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "x", at: 1 }] }),
    ];
    await Promise.all(writes.map((write) => expect(write).rejects.toThrow("UNAUTHENTICATED")));
  });

  test("non-members cannot read snapshots or write any team data", async () => {
    const { outsider, teamId, aliceId, file, addPlace } = await setup();
    const placeId = await addPlace();
    const upload = await file();
    await expect(outsider.query(api.teams.teamSnapshot, { teamId })).rejects.toThrow("NOT_A_MEMBER");
    const writes = [
      outsider.mutation(api.teams.updateMembership, { teamId, colour: "x" }),
      outsider.mutation(api.teams.leaveTeam, { teamId }),
      outsider.mutation(api.teams.renameTeam, { teamId, name: "x" }),
      outsider.action(api.teams.removeMember, { teamId, userId: aliceId }),
      outsider.action(api.teams.addTeamPlace, { bounds: { minQ: -1000, maxQ: 1000, minR: -1000, maxR: 1000 }, teamId, clientId: "x", name: "x", file: upload }),
      outsider.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[0, 0]], at: 1 }),
      outsider.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "x", file: upload }),
      outsider.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "x", at: 1 }] }),
    ];
    await Promise.all(writes.map((write) => expect(write).rejects.toThrow("NOT_A_MEMBER")));
    expect(await outsider.query(api.teams.myTeams)).toEqual([]);
  });

  test("invite preview normalizes codes, hides member names, and returns null for unknown codes", async () => {
    const { alice, bob, outsider, teamId, inviteCode, joinBob } = await setup();
    expect(inviteCode).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/);
    await joinBob();
    expect(await outsider.mutation(api.teams.teamForInvite, { code: ` ${inviteCode.toLowerCase()} ` })).toEqual({ name: "Alice & Bob", memberNames: [] });
    expect(await alice.mutation(api.teams.teamForInvite, { code: "INVALID" })).toBeNull();
    expect(await alice.mutation(api.teams.teamForInvite, { code: "222222" })).toBeNull();
    await expect(bob.action(api.teams.joinTeam, { code: "bad", colour: "red", sharing: "tiles" })).rejects.toThrow("INVALID_INVITE");
    expect((await bob.query(api.teams.myTeams))[0].teamId).toBe(teamId);
  });

  test("invite collisions are retried and teams get distinct codes", async () => {
    const { alice, inviteCode } = await setup();
    const alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
    const random = vi.spyOn(crypto, "getRandomValues");
    const nextCharacter = inviteCode[0] === "A" ? "B" : "A";
    random.mockImplementationOnce((array) => {
      const bytes = array as Uint8Array;
      bytes.set([...inviteCode].map((c) => alphabet.indexOf(c)));
      return array;
    });
    random.mockImplementation((array) => {
      (array as Uint8Array).fill(alphabet.indexOf(nextCharacter));
      return array;
    });
    const second = await alice.action(api.teams.createTeam, { name: "Another team", colour: "blue", sharing: "tiles" });
    expect(second.inviteCode).not.toBe(inviteCode);
    expect(second.inviteCode).toBe(nextCharacter.repeat(8));
    expect(random).toHaveBeenCalledTimes(10);
    expect((await alice.query(api.teams.myTeams))).toHaveLength(2);
  });

  test("only the creator can rename or remove; removal erases trails but keeps credits", async () => {
    const { alice, bob, teamId, bobId, file, joinBob, addPlace, t } = await setup();
    await joinBob();
    const placeId = await addPlace();
    const trail = await file(bob);
    await bob.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "walk", file: trail });
    await bob.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1, 2]], at: 12 });
    await bob.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "history", at: 12 }] });
    await expect(bob.mutation(api.teams.renameTeam, { teamId, name: "Oops" })).rejects.toThrow("CREATOR_ONLY");
    await expect(bob.action(api.teams.removeMember, { teamId, userId: bobId })).rejects.toThrow("CREATOR_ONLY");
    await alice.mutation(api.teams.renameTeam, { teamId, name: "Family" });
    await alice.action(api.teams.removeMember, { teamId, userId: bobId });
    await alice.action(api.teams.removeMember, { teamId, userId: bobId });
    const snapshot = await alice.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.team.name).toBe("Family");
    expect(snapshot.members).toHaveLength(1);
    expect(snapshot.trails).toEqual([]);
    expect(snapshot.tiles[0].by).toBe(bobId);
    expect(snapshot.secrets[0].by).toBe(bobId);
    expect(await t.run((ctx) => ctx.storage.getUrl(trail))).toBeNull();
    await expect(bob.query(api.teams.teamSnapshot, { teamId })).rejects.toThrow("NOT_A_MEMBER");
  });

  test("places are idempotent and tiles are batched, first-wins and retry safe", async () => {
    const { alice, bob, aliceId, teamId, addPlace, file, joinBob } = await setup();
    await joinBob();
    const placeId = await addPlace();
    expect(await bob.action(api.teams.addTeamPlace, { bounds: { minQ: -1000, maxQ: 1000, minR: -1000, maxR: 1000 }, teamId, clientId: "suburb", name: "Ignored", file: await file(bob) })).toBe(placeId);
    const hexes = Array.from({ length: 500 }, (_, q) => [q, -q]);
    expect(await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [...hexes, [0, 0]], at: 100 })).toBe(500);
    expect(await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes, at: 100 })).toBe(0);
    expect(await bob.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes, at: 1 })).toBe(0);
    const snapshot = await bob.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.tiles).toHaveLength(500);
    expect(snapshot.tiles.every((t) => t.by === aliceId && t.at === 100)).toBe(true);
    expect(snapshot.places).toMatchObject([{ placeId, clientId: "suburb", name: "Our suburb", url: expect.any(String) }]);
  });

  test("tile uploads reject foreign places, malformed hexes and excessive batches", async () => {
    const { alice, teamId, addPlace } = await setup();
    const placeId = await addPlace();
    for (const hexes of [[[1]], [[1, 2, 3]], [[1.5, 2]], [[NaN, 2]], Array.from({ length: 1001 }, () => [0, 0])]) {
      await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes, at: 1 })).rejects.toThrow("INVALID_ARGUMENT");
    }
    const second = await alice.action(api.teams.createTeam, { name: "Second", colour: "green", sharing: "tiles" });
    await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId: second.teamId, placeId, hexes: [[0, 0]], at: 1 })).rejects.toThrow("PLACE_NOT_FOUND");
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).tiles).toEqual([]);
  });

  test("trail replacement is per member and opt-out deletes files; re-enabling does not resurrect them", async () => {
    const { alice, bob, t, teamId, file, joinBob } = await setup();
    await joinBob();
    const oldFile = await file();
    const newFile = await file();
    const bobFile = await file(bob);
    await alice.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "same-walk", file: oldFile });
    await alice.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "same-walk", file: oldFile });
    await bob.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "same-walk", file: bobFile });
    await alice.action(api.teams.uploadTeamTrail, { updatedAt: 2, teamId, walkClientId: "same-walk", file: newFile });
    expect(await t.run((ctx) => ctx.storage.getUrl(oldFile))).toBeNull();
    expect((await bob.query(api.teams.teamSnapshot, { teamId })).trails).toHaveLength(2);
    await alice.mutation(api.teams.updateMembership, { teamId, sharing: "tiles" });
    expect((await bob.query(api.teams.teamSnapshot, { teamId })).trails).toHaveLength(1);
    expect(await t.run((ctx) => ctx.storage.getUrl(newFile))).toBeNull();
    await expect(alice.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "x", file: await file() })).rejects.toThrow("TRAIL_SHARING_DISABLED");
    await alice.mutation(api.teams.updateMembership, { teamId, sharing: "tilesAndTrail" });
    expect((await bob.query(api.teams.teamSnapshot, { teamId })).trails).toHaveLength(1);
  });

  test("snapshot also hides stale trails from non-sharing or departed members", async () => {
    const { alice, bob, t, aliceId, teamId, file, joinBob } = await setup();
    await joinBob();
    const stored = await file();
    await t.run(async (ctx) => {
      const member = await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", aliceId)).unique();
      await ctx.db.patch("teamMembers", member!._id, { sharing: "tiles" });
      await ctx.db.insert("teamTrails", { teamId, userId: aliceId, walkClientId: "stale", file: stored, at: 1 });
    });
    expect((await bob.query(api.teams.teamSnapshot, { teamId })).trails).toEqual([]);
    await alice.mutation(api.teams.leaveTeam, { teamId });
    expect((await bob.query(api.teams.teamSnapshot, { teamId })).trails).toEqual([]);
  });

  test("secrets retain the first finder and timestamp through duplicate and older replays", async () => {
    const { alice, bob, aliceId, bobId, teamId, joinBob } = await setup();
    await joinBob();
    await alice.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "heritage", at: 100 }, { secretId: "heritage", at: 90 }] });
    await bob.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "heritage", at: 1 }, { secretId: "nature", at: 50 }] });
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).secrets).toEqual([
      { secretId: "heritage", by: aliceId, at: 100 }, { secretId: "nature", by: bobId, at: 50 },
    ]);
    await bob.mutation(api.teams.leaveTeam, { teamId });
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).secrets).toHaveLength(2);
  });

  test("since uses ingestion time, handles same-millisecond uploads, and filters only tiles", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-20T00:00:00Z"));
    const { alice, teamId, addPlace, file } = await setup();
    const placeId = await addPlace();
    const initial = await alice.query(api.teams.teamSnapshot, { teamId });
    await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1, 2]], at: 100 });
    const first = await alice.query(api.teams.teamSnapshot, { teamId, since: initial.serverTime });
    expect(first.tiles).toHaveLength(1);
    expect(first.serverTime).toBeGreaterThan(initial.serverTime);
    await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[2, 3]], at: 1 });
    await alice.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "walk", file: await file() });
    await alice.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "old", at: 1 }] });
    const next = await alice.query(api.teams.teamSnapshot, { teamId, since: first.serverTime });
    expect(next.tiles).toMatchObject([{ q: 2, r: 3, at: 1 }]);
    expect(next.serverTime).toBeGreaterThan(first.serverTime);
    expect(next.members).toHaveLength(1);
    expect(next.places).toHaveLength(1);
    expect(next.trails).toHaveLength(1);
    expect(next.secrets).toHaveLength(1);
    expect((await alice.query(api.teams.teamSnapshot, { teamId, since: next.serverTime })).tiles).toEqual([]);
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).tiles).toHaveLength(2);
  });

  test("the last departure deletes every team row and owned file, leaving personal data intact", async () => {
    const { t, alice, bob, aliceId, teamId, file, addPlace, joinBob, inviteCode } = await setup();
    await joinBob();
    const placeId = await addPlace();
    const trail = await file();
    const personalFile = await t.run((ctx) => ctx.storage.store(new Blob(["personal"])));
    await t.run((ctx) => ctx.db.insert("walks", { userId: aliceId, clientId: "personal", startedAt: 1, endedAt: 2, distance: 1, newTiles: 1, file: personalFile }));
    await alice.action(api.teams.uploadTeamTrail, { updatedAt: 1, teamId, walkClientId: "walk", file: trail });
    await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1, 2]], at: 1 });
    await alice.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "secret", at: 1 }] });
    const placeFile = await t.run(async (ctx) => (await ctx.db.get("teamPlaces", placeId))!.file);
    await alice.mutation(api.teams.leaveTeam, { teamId });
    expect((await bob.query(api.teams.teamSnapshot, { teamId })).tiles).toHaveLength(1);
    expect(await t.run((ctx) => ctx.storage.getUrl(trail))).toBeNull();
    await bob.mutation(api.teams.leaveTeam, { teamId });
    for (const table of ["teams", "teamMembers", "teamPlaces", "teamTiles", "teamTrails", "teamSecrets"] as const) {
      expect(await t.run((ctx) => ctx.db.query(table).collect())).toEqual([]);
    }
    expect(await t.run((ctx) => ctx.storage.getUrl(placeFile))).toBeNull();
    expect(await t.run((ctx) => ctx.storage.getUrl(personalFile))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("walks").collect())).toHaveLength(1);
    expect(await alice.mutation(api.teams.teamForInvite, { code: inviteCode })).toBeNull();
  });

  test("merged identities use the canonical user's membership", async () => {
    const { t, aliceId, teamId } = await setup();
    const duplicateId = await t.run((ctx) => ctx.db.insert("users", { name: "Duplicate", mergedInto: aliceId }));
    const duplicate = t.withIdentity({ subject: duplicateId });
    const snapshot = await duplicate.query(api.teams.teamSnapshot, { teamId });
    expect(snapshot.members).toMatchObject([{ userId: aliceId, isYou: true }]);
    await duplicate.mutation(api.teams.renameTeam, { teamId, name: "Canonical" });
    expect((await duplicate.query(api.teams.myTeams))[0].name).toBe("Canonical");
  });

  test("large empty maps finish cleanup in scheduled batches without affecting another team", async () => {
    vi.useFakeTimers();
    const { t, alice, teamId, addPlace, inviteCode } = await setup();
    const placeId = await addPlace();
    const other = await alice.action(api.teams.createTeam, { name: "Keep me", colour: "blue", sharing: "tiles" });
    await t.run(async (ctx) => {
      for (let q = 0; q < 1001; q++) {
        const team = await ctx.db.get("teams", teamId);
        await ctx.db.insert("teamTiles", { teamId, placeId, q, r: 0, by: team!.createdBy, at: 1, receivedAt: 1 });
      }
    });
    await alice.mutation(api.teams.leaveTeam, { teamId });
    expect(await alice.mutation(api.teams.teamForInvite, { code: inviteCode })).toBeNull();
    await expect(alice.query(api.teams.teamSnapshot, { teamId })).rejects.toThrow("NOT_A_MEMBER");
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run((ctx) => ctx.db.query("teamTiles").collect())).toEqual([]);
    expect((await alice.query(api.teams.myTeams)).map((team) => team.teamId)).toEqual([other.teamId]);
  });

  test("join HTML opens Walkies and handles malformed invites without leaking names", async () => {
    const { t, alice, teamId, inviteCode } = await setup();
    await alice.mutation(api.teams.renameTeam, { teamId, name: '<script>alert("x")</script> & team' });
    const response = await t.fetch(`/join/${inviteCode.toLowerCase()}`);
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("text/html");
    const html = await response.text();
    expect(html).toContain(`walkies://join/${inviteCode}`);
    expect(html).toContain("window.location.href");
    expect(html).not.toContain("script&gt;");
    expect(html).not.toContain("Alice &amp; Bob");
    expect(html).not.toContain("Alice");
    const unknown = await t.fetch("/join/bad-code");
    expect(unknown.status).toBe(200);
    expect(await unknown.text()).toContain("Ask someone in the team");
  });
});

describe("team review regressions", () => {
  test("removal rotates the invite and stays enforced across later removals until an explicit fresh invite", async () => {
    const { alice, bob, outsider, bobId, teamId, inviteCode, joinBob, t } = await setup();
    await joinBob();
    await outsider.action(api.teams.joinTeam, { code: inviteCode, colour: "red", sharing: "tiles" });
    const eveId = (await outsider.query(api.teams.myTeams))[0].membership.userId;
    await expect(bob.action(api.teams.newInviteCode, { teamId })).rejects.toThrow("CREATOR_ONLY");
    await alice.action(api.teams.removeMember, { teamId, userId: bobId });
    const rotated = (await alice.query(api.teams.teamSnapshot, { teamId })).team.inviteCode;
    expect(rotated).not.toBe(inviteCode);
    await expect(joinBob()).rejects.toThrow("INVALID_INVITE");
    await expect(bob.action(api.teams.joinTeam, { code: rotated, colour: "blue", sharing: "tilesAndTrail" })).rejects.toThrow("MEMBER_REMOVED");
    await alice.action(api.teams.removeMember, { teamId, userId: eveId });
    const again = (await alice.query(api.teams.teamSnapshot, { teamId })).team.inviteCode;
    await expect(bob.action(api.teams.joinTeam, { code: again, colour: "blue", sharing: "tiles" })).rejects.toThrow("MEMBER_REMOVED");
    expect(await bob.mutation(api.teams.teamForInvite, { code: again })).toBeNull();
    const fresh = await alice.action(api.teams.newInviteCode, { teamId });
    expect(await bob.action(api.teams.joinTeam, { code: fresh, colour: "blue", sharing: "tiles" })).toBe(teamId);
    expect(await t.run((ctx) => ctx.db.query("teamRemovals").collect())).toHaveLength(2);
  });

  test("failed previews and joins share a durable hourly limit per canonical user", async () => {
    vi.useFakeTimers();
    const { t, alice, aliceId, bob, inviteCode } = await setup();
    for (let i = 0; i < 15; i++) {
      expect(await alice.mutation(api.teams.teamForInvite, { code: "BAD" })).toBeNull();
      await expect(alice.action(api.teams.joinTeam, { code: "BAD", colour: "x", sharing: "tiles" })).rejects.toThrow("INVALID_INVITE");
    }
    const duplicateId = await t.run((ctx) => ctx.db.insert("users", { mergedInto: aliceId }));
    await expect(t.withIdentity({ subject: duplicateId }).mutation(api.teams.teamForInvite, { code: inviteCode })).rejects.toThrow("RATE_LIMITED");
    await expect(alice.action(api.teams.joinTeam, { code: inviteCode, colour: "x", sharing: "tiles" })).rejects.toThrow("RATE_LIMITED");
    expect(await bob.mutation(api.teams.teamForInvite, { code: inviteCode })).toEqual({ name: "Alice & Bob", memberNames: [] });
    vi.setSystemTime(Date.now() + 60 * 60 * 1000);
    expect(await alice.mutation(api.teams.teamForInvite, { code: inviteCode })).not.toBeNull();
  });

  test("public landing pages don't resolve codes or disclose team or member names", async () => {
    const { t, inviteCode } = await setup();
    const unknownCode = inviteCode === "AAAAAAAA" ? "BBBBBBBB" : "AAAAAAAA";
    const known = await t.fetch(`/join/${inviteCode}`), unknown = await t.fetch(`/join/${unknownCode}`);
    expect(known.status).toBe(200); expect(unknown.status).toBe(200);
    expect(known.headers.get("Cache-Control")).toBe("no-store");
    const html = await known.text();
    expect(html).not.toContain("Alice"); expect(html).not.toContain("Bob");
    expect(html.replaceAll(inviteCode, "CODE")).toBe((await unknown.text()).replaceAll(unknownCode, "CODE"));
  });

  test("eight members include the creator; a full team still accepts a member's retry", async () => {
    const { t, alice, inviteCode, teamId } = await setup();
    const users = await t.run(async (ctx) => {
      const ids = [];
      for (let i = 0; i < 8; i++) ids.push(await ctx.db.insert("users", { name: `Member ${i}` }));
      return ids;
    });
    for (const id of users.slice(0, 7)) await t.withIdentity({ subject: id }).action(api.teams.joinTeam, { code: inviteCode, colour: "x", sharing: "tiles" });
    await expect(t.withIdentity({ subject: users[7] }).action(api.teams.joinTeam, { code: inviteCode, colour: "x", sharing: "tiles" })).rejects.toThrow("TEAM_FULL");
    expect(await alice.action(api.teams.joinTeam, { code: inviteCode, colour: "ignored", sharing: "tiles" })).toBe(teamId);
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).members).toHaveLength(8);
  });

  test("team files reject personal, foreign and already-used storage IDs without deleting them", async () => {
    const { t, alice, bob, teamId, file, joinBob } = await setup();
    await joinBob();
    const personal = await t.run((ctx) => ctx.storage.store(new Blob(["personal"])));
    const victim = await file(bob);
    const upload = (storageId: typeof personal, walkClientId = "walk") => alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId, file: storageId, updatedAt: 1 });
    await expect(upload(personal)).rejects.toThrow("INVALID_UPLOAD");
    await expect(upload(victim)).rejects.toThrow("INVALID_UPLOAD");
    const own = await file();
    await upload(own);
    await expect(upload(own, "another-walk")).rejects.toThrow("INVALID_UPLOAD");
    const other = await alice.action(api.teams.createTeam, { name: "Other", colour: "x", sharing: "tilesAndTrail" });
    await expect(alice.action(api.teams.uploadTeamTrail, { teamId: other.teamId, walkClientId: "walk", file: own, updatedAt: 1 })).rejects.toThrow("INVALID_UPLOAD");
    await expect(alice.action(api.teams.addTeamPlace, { teamId, clientId: "bad", name: "bad", file: victim, bounds: { minQ: 0, maxQ: 1, minR: 0, maxR: 1 } })).rejects.toThrow("INVALID_UPLOAD");
    await expect(alice.mutation(api.sync.saveWalk, { clientId: "personal", file: own, startedAt: 1, endedAt: 2, distance: 1, newTiles: 0 })).rejects.toThrow("Team files cannot");
    for (const id of [personal, victim, own]) expect(await t.run((ctx) => ctx.storage.getUrl(id))).not.toBeNull();
  });

  test("unused duplicates and validation failures are deleted, but retries preserve the adopted file", async () => {
    const { t, alice, teamId, file, addPlace } = await setup();
    const placeId = await addPlace();
    const duplicate = await file();
    const args = { teamId, clientId: "suburb", name: "Ignored", file: duplicate, bounds: { minQ: 0, maxQ: 1, minR: 0, maxR: 1 } };
    expect(await alice.action(api.teams.addTeamPlace, args)).toBe(placeId);
    expect(await t.run((ctx) => ctx.storage.getUrl(duplicate))).toBeNull();
    const adopted = await t.run(async (ctx) => (await ctx.db.get("teamPlaces", placeId))!.file);
    await alice.action(api.teams.addTeamPlace, { ...args, file: adopted });
    expect(await t.run((ctx) => ctx.storage.getUrl(adopted))).not.toBeNull();
    const badPlace = await file();
    await expect(alice.action(api.teams.addTeamPlace, { ...args, clientId: "new", file: badPlace, bounds: { minQ: 2, maxQ: 1, minR: 0, maxR: 1 } })).rejects.toThrow("INVALID_ARGUMENT");
    expect(await t.run((ctx) => ctx.storage.getUrl(badPlace))).toBeNull();
    await alice.mutation(api.teams.updateMembership, { teamId, sharing: "tiles" });
    const badTrail = await file();
    await expect(alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "x", file: badTrail, updatedAt: 1 })).rejects.toThrow("TRAIL_SHARING_DISABLED");
    expect(await t.run((ctx) => ctx.storage.getUrl(badTrail))).toBeNull();
  });

  test("abandoned uploads expire but consumed uploads survive expiration", async () => {
    vi.useFakeTimers();
    const { t, alice, teamId, file } = await setup();
    const unused = await file(), used = await file();
    await alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "x", file: used, updatedAt: 1 });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run((ctx) => ctx.storage.getUrl(unused))).toBeNull();
    expect(await t.run((ctx) => ctx.storage.getUrl(used))).not.toBeNull();
  });

  test("stale or equal-version retries can't replace a newer trail", async () => {
    const { t, alice, teamId, file } = await setup();
    const newest = await file();
    await alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "x", file: newest, updatedAt: 20 });
    for (const updatedAt of [10, 20]) {
      const stale = await file();
      await alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "x", file: stale, updatedAt });
      expect(await t.run((ctx) => ctx.storage.getUrl(stale))).toBeNull();
    }
    expect(await t.run(async (ctx) => (await ctx.db.query("teamTrails").unique())!.file)).toBe(newest);
    expect(await t.run((ctx) => ctx.storage.getUrl(newest))).not.toBeNull();
  });

  test("grid bounds and the transactional tile cap reject fake coordinates and over-cap inserts", async () => {
    const { t, alice, teamId, addPlace } = await setup();
    const placeId = await addPlace();
    await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1001, 0]], at: 1 })).rejects.toThrow("INVALID_ARGUMENT");
    await t.run((ctx) => ctx.db.patch("teamPlaces", placeId, { tileCount: 49_999 }));
    await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1, 1], [2, 2]], at: 1 })).rejects.toThrow("TILE_LIMIT");
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).tiles).toEqual([]);
    expect(await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1, 1]], at: 1 })).toBe(1);
    expect(await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1, 1]], at: 1 })).toBe(0);
    await expect(alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[2, 2]], at: 1 })).rejects.toThrow("TILE_LIMIT");
  });

  test("pagination splits a same-time batch without gaps and freezes the ingestion watermark", async () => {
    const { t, alice, aliceId, teamId, addPlace } = await setup();
    const placeId = await addPlace();
    const baseline = (await alice.query(api.teams.teamSnapshot, { teamId })).serverTime;
    await t.run(async (ctx) => {
      for (let q = 0; q < 2101; q++) await ctx.db.insert("teamTiles", { teamId, placeId, q, r: 0, by: aliceId, at: q, receivedAt: baseline + 1 });
      await ctx.db.patch("teams", teamId, { tilesUpdatedAt: baseline + 1 });
    });
    let page = await alice.query(api.teams.teamSnapshot, { teamId, since: baseline });
    expect(page.tiles).toHaveLength(1000); expect(page.more).toBe(true);
    const watermark = page.serverTime;
    const seen = page.tiles.map((tile) => tile.q);
    await alice.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[-1, -1]], at: 1 });
    await expect(alice.query(api.teams.teamSnapshot, { teamId, since: baseline + 1, cursor: page.cursor! })).rejects.toThrow("INVALID_ARGUMENT");
    while (page.more) {
      page = await alice.query(api.teams.teamSnapshot, { teamId, since: baseline, cursor: page.cursor! });
      expect(page.serverTime).toBe(watermark); expect(page.tiles.length).toBeLessThanOrEqual(1000);
      seen.push(...page.tiles.map((tile) => tile.q));
    }
    expect(page.cursor).toBeNull(); expect(seen).toHaveLength(2101); expect(new Set(seen).size).toBe(2101);
    expect((await alice.query(api.teams.teamSnapshot, { teamId, since: watermark })).tiles).toMatchObject([{ q: -1, r: -1 }]);
    const full = await alice.query(api.teams.teamSnapshot, { teamId });
    expect(full.tiles).toHaveLength(1000); expect(full.more).toBe(true);
  });

  test("trails, places and secrets have bounded counts with retries allowed at the limits", async () => {
    const { t, alice, aliceId, teamId, file, addPlace } = await setup();
    const placeId = await addPlace();
    await t.run(async (ctx) => {
      const place = (await ctx.db.get("teamPlaces", placeId))!;
      for (let i = 1; i < 16; i++) await ctx.db.insert("teamPlaces", { teamId, clientId: `place-${i}`, name: "x", file: place.file, addedBy: aliceId, updatedAt: 1 });
      for (let i = 0; i < 64; i++) await ctx.db.insert("teamTrails", { teamId, userId: aliceId, walkClientId: `walk-${i}`, file: place.file, at: 1, updatedAt: 1 });
      for (let i = 0; i < 1000; i++) await ctx.db.insert("teamSecrets", { teamId, secretId: `secret-${i}`, by: aliceId, at: 1 });
    });
    await expect(addPlace("overflow")).rejects.toThrow("PLACE_LIMIT");
    const excess = await file();
    await expect(alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "overflow", file: excess, updatedAt: 1 })).rejects.toThrow("TRAIL_LIMIT");
    expect(await t.run((ctx) => ctx.storage.getUrl(excess))).toBeNull();
    await alice.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "secret-0", at: 0 }] });
    await expect(alice.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "overflow", at: 1 }] })).rejects.toThrow("SECRET_LIMIT");
  });

  test("legacy trail cleanup is bounded and cannot delete routes shared after opting back in", async () => {
    vi.useFakeTimers();
    const { t, alice, aliceId, teamId, file } = await setup();
    const legacy = await t.run((ctx) => ctx.storage.store(new Blob(["legacy"])));
    await t.run(async (ctx) => {
      for (let i = 0; i < 600; i++) await ctx.db.insert("teamTrails", { teamId, userId: aliceId, walkClientId: `old-${i}`, file: legacy, at: 1 });
    });
    await alice.mutation(api.teams.updateMembership, { teamId, sharing: "tiles" });
    expect(await t.run((ctx) => ctx.db.query("teamTrails").collect())).toHaveLength(350);
    await alice.mutation(api.teams.updateMembership, { teamId, sharing: "tilesAndTrail" });
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).trails).toEqual([]);
    // Let enough old rows drain to fall below the admission cap before uploading.
    await t.mutation(internal.teams.cleanupMemberTrails, {
      teamId, userId: aliceId,
      memberId: await t.run(async (ctx) => (await ctx.db.query("teamMembers").unique())!._id), epoch: 0,
    });
    await t.mutation(internal.teams.cleanupMemberTrails, {
      teamId, userId: aliceId,
      memberId: await t.run(async (ctx) => (await ctx.db.query("teamMembers").unique())!._id), epoch: 0,
    });
    const fresh = await file();
    await alice.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "fresh", file: fresh, updatedAt: 1 });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).trails).toMatchObject([{ walkClientId: "fresh" }]);
    expect(await t.run((ctx) => ctx.storage.getUrl(fresh))).not.toBeNull();
    // Unknown legacy ownership must not delete a possibly shared personal file.
    expect(await t.run((ctx) => ctx.storage.getUrl(legacy))).not.toBeNull();
  });

  test("account merging moves team ownership, membership, uploads and credits; overlapping memberships keep canonical privacy", async () => {
    const { t, alice, aliceId, bob, bobId, teamId, file, addPlace, joinBob } = await setup();
    await joinBob();
    const placeId = await addPlace();
    const duplicateOnly = await bob.action(api.teams.createTeam, { name: "Duplicate owns this", colour: "blue", sharing: "tilesAndTrail" });
    const sharedFile = await file(bob), soloFile = await file(bob);
    await bob.action(api.teams.uploadTeamTrail, { teamId, walkClientId: "duplicate-shared", file: sharedFile, updatedAt: 1 });
    await bob.action(api.teams.uploadTeamTrail, { teamId: duplicateOnly.teamId, walkClientId: "duplicate-solo", file: soloFile, updatedAt: 1 });
    await bob.mutation(api.teams.uploadTeamTiles, { teamId, placeId, hexes: [[1, 2]], at: 1 });
    await bob.mutation(api.teams.recordTeamSecrets, { teamId, secrets: [{ secretId: "credit", at: 1 }] });
    await alice.mutation(api.teams.updateMembership, { teamId, sharing: "tiles" });
    const beforeMerge = (await alice.query(api.teams.teamSnapshot, { teamId })).serverTime;
    await t.run(async (ctx) => {
      await ctx.db.patch("users", aliceId, { email: "merge@example.com", emailVerified: true });
      await ctx.db.patch("users", bobId, { email: "merge@example.com", emailVerified: true });
    });
    expect(await t.mutation(internal.users.mergeDuplicateUsers, {})).toEqual({ merged: 1 });
    const shared = await alice.query(api.teams.teamSnapshot, { teamId });
    expect(shared.members).toMatchObject([{ userId: aliceId, sharing: "tiles" }]);
    expect(shared.trails).toEqual([]); expect(shared.tiles[0].by).toBe(aliceId); expect(shared.secrets[0].by).toBe(aliceId);
    expect((await alice.query(api.teams.teamSnapshot, { teamId, since: beforeMerge })).tiles).toMatchObject([{ by: aliceId }]);
    expect(await t.run((ctx) => ctx.storage.getUrl(sharedFile))).toBeNull();
    const solo = await alice.query(api.teams.teamSnapshot, { teamId: duplicateOnly.teamId });
    expect(solo.team.createdBy).toBe(aliceId); expect(solo.trails).toMatchObject([{ by: aliceId }]);
    await alice.mutation(api.teams.renameTeam, { teamId: duplicateOnly.teamId, name: "Still manageable" });
    await bob.mutation(api.teams.updateMembership, { teamId: duplicateOnly.teamId, sharing: "tiles" });
    expect(await t.run((ctx) => ctx.storage.getUrl(soloFile))).toBeNull();
    expect((await alice.query(api.teams.teamSnapshot, { teamId: duplicateOnly.teamId })).trails).toEqual([]);
  });
});

describe("team cleanup and merge boundaries", () => {
  test("new upload and invite APIs reject signed-out and non-creator callers", async () => {
    const { t, outsider, teamId } = await setup();
    await expect(t.action(api.teams.uploadFile, { json: "{}" })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.action(api.teams.newInviteCode, { teamId })).rejects.toThrow("UNAUTHENTICATED");
    await expect(outsider.action(api.teams.newInviteCode, { teamId })).rejects.toThrow("NOT_A_MEMBER");
    await expect(outsider.action(api.teams.uploadFile, { json: "not json" })).rejects.toThrow("INVALID_ARGUMENT");
    await expect(outsider.action(api.teams.uploadFile, { json: `"${"x".repeat(2 * 1024 * 1024)}"` })).rejects.toThrow("INVALID_ARGUMENT");
  });

  test("a departure and immediate rejoin cannot reveal pending legacy trails", async () => {
    vi.useFakeTimers();
    const { t, alice, bob, bobId, teamId, inviteCode, joinBob } = await setup();
    await joinBob();
    const file = await t.run((ctx) => ctx.storage.store(new Blob(["legacy"])));
    await t.run(async (ctx) => {
      for (let i = 0; i < 600; i++) await ctx.db.insert("teamTrails", { teamId, userId: bobId, walkClientId: `old-${i}`, file, at: 1 });
    });
    await bob.mutation(api.teams.leaveTeam, { teamId });
    expect(await t.run((ctx) => ctx.db.query("teamTrails").collect())).toHaveLength(350);
    await bob.action(api.teams.joinTeam, { code: inviteCode, colour: "blue", sharing: "tilesAndTrail" });
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).trails).toEqual([]);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run((ctx) => ctx.db.query("teamTrails").collect())).toEqual([]);
  });

  test("merging during pending opt-out cleanup does not revive routes from an old sharing epoch", async () => {
    vi.useFakeTimers();
    const { t, alice, aliceId, bob, bobId } = await setup();
    const { teamId } = await bob.action(api.teams.createTeam, { name: "Bob's team", colour: "blue", sharing: "tilesAndTrail" });
    const file = await t.run((ctx) => ctx.storage.store(new Blob(["legacy"])));
    await t.run(async (ctx) => {
      const member = (await ctx.db.query("teamMembers").withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", bobId)).unique())!;
      for (let i = 0; i < 600; i++) await ctx.db.insert("teamTrails", { teamId, userId: bobId, walkClientId: `old-${i}`, file, at: 1, memberId: member._id, epoch: 0 });
      await ctx.db.patch("users", aliceId, { email: "merge@example.com", emailVerified: true });
      await ctx.db.patch("users", bobId, { email: "merge@example.com", emailVerified: true });
    });
    await bob.mutation(api.teams.updateMembership, { teamId, sharing: "tiles" });
    await bob.mutation(api.teams.updateMembership, { teamId, sharing: "tilesAndTrail" });
    await t.mutation(internal.users.mergeDuplicateUsers, {});
    expect((await alice.query(api.teams.teamSnapshot, { teamId })).trails).toEqual([]);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run((ctx) => ctx.db.query("teamTrails").collect())).toEqual([]);
  });

  test("large account-merge attribution finishes in batches and retains removed-member restrictions", async () => {
    vi.useFakeTimers();
    const { t, alice, aliceId, bob, bobId, teamId, joinBob, addPlace } = await setup();
    await joinBob();
    const placeId = await addPlace();
    await t.run(async (ctx) => {
      for (let q = 0; q < 1100; q++) await ctx.db.insert("teamTiles", { teamId, placeId, q, r: 0, by: bobId, at: 1, receivedAt: 1 });
      await ctx.db.patch("users", aliceId, { email: "merge@example.com", emailVerified: true });
      await ctx.db.patch("users", bobId, { email: "merge@example.com", emailVerified: true });
    });
    const { teamId: removedTeam, inviteCode: oldCode } = await alice.action(api.teams.createTeam, { name: "Removed", colour: "red", sharing: "tiles" });
    await bob.action(api.teams.joinTeam, { code: oldCode, colour: "blue", sharing: "tiles" });
    await alice.action(api.teams.removeMember, { teamId: removedTeam, userId: bobId });
    for (let i = 0; i < 15; i++) {
      await alice.mutation(api.teams.teamForInvite, { code: "BAD" });
      await bob.mutation(api.teams.teamForInvite, { code: "BAD" });
    }
    await t.mutation(internal.users.mergeDuplicateUsers, {});
    expect(await t.run((ctx) => ctx.db.query("teamTiles").withIndex("by_user", (q) => q.eq("by", bobId)).collect())).toHaveLength(600);
    await expect(alice.mutation(api.teams.teamForInvite, { code: "BAD" })).rejects.toThrow("RATE_LIMITED");
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run((ctx) => ctx.db.query("teamTiles").withIndex("by_user", (q) => q.eq("by", bobId)).collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("teamTiles").withIndex("by_user", (q) => q.eq("by", aliceId)).collect())).toHaveLength(1100);
    expect(await t.run((ctx) => ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", removedTeam).eq("userId", aliceId)).unique())).not.toBeNull();
  });
});

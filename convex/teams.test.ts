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
    name: "Alice & Bob", colour: "#e67834",
  });
  const joinBob = () => bob.action(api.teams.joinTeam, { code: inviteCode, colour: "#467cba", name: "Dad" });
  return { t, alice, bob, outsider, aliceId, bobId, teamId, inviteCode, joinBob };
}

afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

describe("team membership", () => {
  test("create, join, edit and leave preserve membership and personal progress", async () => {
    const { alice, bob, teamId, inviteCode, joinBob, t, aliceId } = await setup();
    expect((await alice.query(api.teams.myTeams))[0]).toMatchObject({
      teamId, name: "Alice & Bob", createdBy: aliceId, inviteCode,
      members: [{ name: "Alice", colour: "#e67834", isYou: true }],
    });
    await joinBob();
    await bob.action(api.teams.joinTeam, { code: inviteCode, colour: "ignored", name: "ignored" });
    let team = (await alice.query(api.teams.myTeams))[0];
    expect(team.members).toHaveLength(2);
    expect(team.members.find((m) => !m.isYou)).toMatchObject({ name: "Dad", colour: "#467cba" });
    await bob.mutation(api.teams.updateMembership, { teamId, colour: "purple", name: " Bob " });
    team = (await bob.query(api.teams.myTeams))[0];
    expect(team.members.find((m) => m.isYou)).toMatchObject({ name: "Bob", colour: "purple" });
    await t.run((ctx) => ctx.db.insert("secrets", { userId: aliceId, secretId: "mine", foundAt: 1 }));
    await bob.mutation(api.teams.leaveTeam, { teamId });
    expect(await bob.query(api.teams.myTeams)).toEqual([]);
    expect((await alice.query(api.teams.myTeams))[0].members).toHaveLength(1);
    await alice.mutation(api.teams.leaveTeam, { teamId });
    for (const table of ["teams", "teamMembers", "teamRemovals"] as const) {
      expect(await t.run((ctx) => ctx.db.query(table).collect())).toEqual([]);
    }
    expect(await t.run((ctx) => ctx.db.query("secrets").collect())).toHaveLength(1);
    expect(await alice.mutation(api.teams.teamForInvite, { code: inviteCode })).toBeNull();
  });

  test("member and team names are trimmed and invalid changes are atomic", async () => {
    const { alice, teamId } = await setup();
    const created = await alice.action(api.teams.createTeam, { name: " Family ", colour: " blue ", memberName: " Mike " });
    expect((await alice.query(api.teams.myTeams)).find((team) => team.teamId === created.teamId)).toMatchObject({
      name: "Family", members: [{ name: "Mike", colour: "blue" }],
    });
    await expect(alice.mutation(api.teams.updateMembership, { teamId, name: " ", colour: "rose" })).rejects.toThrow("INVALID_ARGUMENT");
    expect((await alice.query(api.teams.myTeams)).find((team) => team.teamId === teamId)?.members[0].colour).toBe("#e67834");
    await expect(alice.mutation(api.teams.renameTeam, { teamId, name: "x".repeat(101) })).rejects.toThrow("INVALID_ARGUMENT");
  });

  test("last departure cleans removal records in bounded batches", async () => {
    vi.useFakeTimers();
    const { t, alice, aliceId, teamId } = await setup();
    const other = await alice.action(api.teams.createTeam, { name: "Keep", colour: "blue" });
    await t.run(async (ctx) => {
      for (let i = 0; i < 501; i++) {
        const userId = await ctx.db.insert("users", {});
        await ctx.db.insert("teamRemovals", { teamId, userId, epoch: 0 });
      }
      await ctx.db.insert("teamRemovals", { teamId: other.teamId, userId: aliceId, epoch: 0 });
    });
    await alice.mutation(api.teams.leaveTeam, { teamId });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run((ctx) => ctx.db.get("teams", teamId))).toBeNull();
    expect(await t.run((ctx) => ctx.db.query("teamRemovals").collect())).toMatchObject([{ teamId: other.teamId }]);
    expect((await alice.query(api.teams.myTeams)).map((team) => team.teamId)).toEqual([other.teamId]);
  });

  test("members see each other's photos; outsiders cannot list the team", async () => {
    const { t, alice, bob, outsider, aliceId, bobId, joinBob } = await setup();
    await t.run((ctx) => ctx.db.patch("users", aliceId, { picture: "https://lh3.googleusercontent.com/alice" }));
    await joinBob();
    const team = (await bob.query(api.teams.myTeams))[0];
    expect(team.members.find((m) => m.userId === aliceId)?.picture).toBe("https://lh3.googleusercontent.com/alice");
    expect(team.members.find((m) => m.userId === bobId)?.picture).toBeNull();
    expect(await alice.query(api.users.me)).toMatchObject({ picture: "https://lh3.googleusercontent.com/alice" });
    expect(await outsider.query(api.teams.myTeams)).toEqual([]);
  });

  test("all public membership endpoints require sign-in and writes require membership", async () => {
    const { t, outsider, teamId, inviteCode, bobId } = await setup();
    await expect(t.query(api.teams.myTeams)).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.mutation(api.teams.teamForInvite, { code: inviteCode })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.action(api.teams.createTeam, { name: "x", colour: "red" })).rejects.toThrow("UNAUTHENTICATED");
    await expect(t.action(api.teams.joinTeam, { code: inviteCode, colour: "red" })).rejects.toThrow("UNAUTHENTICATED");
    for (const [caller, error] of [[t, "UNAUTHENTICATED"], [outsider, "NOT_A_MEMBER"]] as const) {
      await expect(caller.mutation(api.teams.updateMembership, { teamId, colour: "red" })).rejects.toThrow(error);
      await expect(caller.mutation(api.teams.leaveTeam, { teamId })).rejects.toThrow(error);
      await expect(caller.mutation(api.teams.renameTeam, { teamId, name: "x" })).rejects.toThrow(error);
      await expect(caller.action(api.teams.removeMember, { teamId, userId: bobId })).rejects.toThrow(error);
      await expect(caller.action(api.teams.newInviteCode, { teamId })).rejects.toThrow(error);
    }
  });

  test("only creators rename and remove, and removed memberships disappear", async () => {
    const { alice, bob, teamId, bobId, joinBob } = await setup();
    await joinBob();
    await expect(bob.mutation(api.teams.renameTeam, { teamId, name: "Oops" })).rejects.toThrow("CREATOR_ONLY");
    await expect(bob.action(api.teams.removeMember, { teamId, userId: bobId })).rejects.toThrow("CREATOR_ONLY");
    await alice.mutation(api.teams.renameTeam, { teamId, name: "Family" });
    await alice.action(api.teams.removeMember, { teamId, userId: bobId });
    await alice.action(api.teams.removeMember, { teamId, userId: bobId });
    expect((await alice.query(api.teams.myTeams))[0]).toMatchObject({ name: "Family", members: [{ isYou: true }] });
    expect(await bob.query(api.teams.myTeams)).toEqual([]);
  });

  test("account merging keeps canonical membership, moves ownership and preserves invite restrictions", async () => {
    const { t, alice, aliceId, bob, bobId, teamId, joinBob } = await setup();
    await joinBob();
    const solo = await bob.action(api.teams.createTeam, { name: "Bob's team", colour: "blue", memberName: " Bobby " });
    const removed = await alice.action(api.teams.createTeam, { name: "Removed", colour: "red" });
    await bob.action(api.teams.joinTeam, { code: removed.inviteCode, colour: "blue" });
    await alice.action(api.teams.removeMember, { teamId: removed.teamId, userId: bobId });
    for (let i = 0; i < 15; i++) {
      await alice.mutation(api.teams.teamForInvite, { code: "BAD" });
      await bob.mutation(api.teams.teamForInvite, { code: "BAD" });
    }
    await t.run(async (ctx) => {
      await ctx.db.patch("users", aliceId, { email: "merge@example.com", emailVerified: true });
      await ctx.db.patch("users", bobId, { email: "merge@example.com", emailVerified: true });
    });
    expect(await t.mutation(internal.users.mergeDuplicateUsers, {})).toEqual({ merged: 1 });
    const teams = await alice.query(api.teams.myTeams);
    expect(teams.find((team) => team.teamId === teamId)?.members).toMatchObject([{ userId: aliceId, name: "Alice", colour: "#e67834" }]);
    expect(teams.find((team) => team.teamId === solo.teamId)).toMatchObject({ createdBy: aliceId, members: [{ userId: aliceId, name: "Bobby", isYou: true }] });
    expect(await bob.query(api.teams.myTeams)).toEqual(teams);
    await bob.mutation(api.teams.renameTeam, { teamId: solo.teamId, name: "Still manageable" });
    expect(await t.run((ctx) => ctx.db.query("teamRemovals").withIndex("by_team_user", (q) => q.eq("teamId", removed.teamId).eq("userId", aliceId)).unique())).not.toBeNull();
    await expect(alice.mutation(api.teams.teamForInvite, { code: "BAD" })).rejects.toThrow("RATE_LIMITED");
    expect(await t.mutation(internal.users.mergeDuplicateUsers, {})).toEqual({ merged: 0 });
  });

  test("invite preview normalizes codes, hides member names, and returns null for unknown codes", async () => {
    const { alice, bob, outsider, teamId, inviteCode, joinBob } = await setup();
    expect(inviteCode).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/);
    await joinBob();
    expect(await outsider.mutation(api.teams.teamForInvite, { code: ` ${inviteCode.toLowerCase()} ` })).toEqual({ name: "Alice & Bob", memberNames: [] });
    expect(await alice.mutation(api.teams.teamForInvite, { code: "INVALID" })).toBeNull();
    expect(await alice.mutation(api.teams.teamForInvite, { code: "222222" })).toBeNull();
    await expect(bob.action(api.teams.joinTeam, { code: "bad", colour: "red" })).rejects.toThrow("INVALID_INVITE");
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
    const second = await alice.action(api.teams.createTeam, { name: "Another team", colour: "blue" });
    expect(second.inviteCode).not.toBe(inviteCode);
    expect(second.inviteCode).toBe(nextCharacter.repeat(8));
    expect(random).toHaveBeenCalledTimes(10);
    expect((await alice.query(api.teams.myTeams))).toHaveLength(2);
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

  test("removal rotates the invite and stays enforced across later removals until an explicit fresh invite", async () => {
    const { alice, bob, outsider, bobId, teamId, inviteCode, joinBob, t } = await setup();
    await joinBob();
    await outsider.action(api.teams.joinTeam, { code: inviteCode, colour: "red" });
    const eveId = (await outsider.query(api.teams.myTeams))[0].members.find((member) => member.isYou)!.userId;
    await expect(bob.action(api.teams.newInviteCode, { teamId })).rejects.toThrow("CREATOR_ONLY");
    await alice.action(api.teams.removeMember, { teamId, userId: bobId });
    const rotated = (await alice.query(api.teams.myTeams))[0].inviteCode;
    expect(rotated).not.toBe(inviteCode);
    await expect(joinBob()).rejects.toThrow("INVALID_INVITE");
    await expect(bob.action(api.teams.joinTeam, { code: rotated, colour: "blue" })).rejects.toThrow("MEMBER_REMOVED");
    await alice.action(api.teams.removeMember, { teamId, userId: eveId });
    const again = (await alice.query(api.teams.myTeams))[0].inviteCode;
    await expect(bob.action(api.teams.joinTeam, { code: again, colour: "blue" })).rejects.toThrow("MEMBER_REMOVED");
    expect(await bob.mutation(api.teams.teamForInvite, { code: again })).toBeNull();
    const fresh = await alice.action(api.teams.newInviteCode, { teamId });
    expect(await bob.action(api.teams.joinTeam, { code: fresh, colour: "blue" })).toBe(teamId);
    expect(await t.run((ctx) => ctx.db.query("teamRemovals").collect())).toHaveLength(2);
  });

  test("failed previews and joins share a durable hourly limit per canonical user", async () => {
    vi.useFakeTimers();
    const { t, alice, aliceId, bob, inviteCode } = await setup();
    for (let i = 0; i < 15; i++) {
      expect(await alice.mutation(api.teams.teamForInvite, { code: "BAD" })).toBeNull();
      await expect(alice.action(api.teams.joinTeam, { code: "BAD", colour: "x" })).rejects.toThrow("INVALID_INVITE");
    }
    const duplicateId = await t.run((ctx) => ctx.db.insert("users", { mergedInto: aliceId }));
    await expect(t.withIdentity({ subject: duplicateId }).mutation(api.teams.teamForInvite, { code: inviteCode })).rejects.toThrow("RATE_LIMITED");
    await expect(alice.action(api.teams.joinTeam, { code: inviteCode, colour: "x" })).rejects.toThrow("RATE_LIMITED");
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
    for (const id of users.slice(0, 7)) await t.withIdentity({ subject: id }).action(api.teams.joinTeam, { code: inviteCode, colour: "x" });
    await expect(t.withIdentity({ subject: users[7] }).action(api.teams.joinTeam, { code: inviteCode, colour: "x" })).rejects.toThrow("TEAM_FULL");
    expect(await alice.action(api.teams.joinTeam, { code: inviteCode, colour: "ignored" })).toBe(teamId);
    expect((await alice.query(api.teams.myTeams))[0].members).toHaveLength(8);
  });
});

# Team membership API

Implemented in `convex/teams.ts`; product decisions are in [coop.md](coop.md). Teams contain membership only. Personal places, walks, tiles, secrets and progression use the personal sync API.

## Conventions

All public functions require a signed-in Convex Auth session. `currentUserId` resolves merged accounts. IDs are opaque Convex IDs; times are milliseconds since the Unix epoch. Names are trimmed, nonempty and at most 100 characters. Colours are nonempty strings up to 64 characters. Failures throw `ConvexError({ code, message })`.

| Function | Kind | Arguments | Returns |
| --- | --- | --- | --- |
| `createTeam` | action | `{ name, colour, memberName?: string }` | `{ teamId, inviteCode }` |
| `teamForInvite` | mutation | `{ code }` | `{ name, memberNames: [] }` or `null` |
| `joinTeam` | action | `{ code, colour, name?: string }` | `teamId` |
| `myTeams` | query | `{}` | Array of teams with all members |
| `updateMembership` | mutation | `{ teamId, colour?: string, name?: string }` | `null` |
| `leaveTeam` | mutation | `{ teamId }` | `null` |
| `renameTeam` | mutation | `{ teamId, name }` | `null` |
| `removeMember` | action | `{ teamId, userId }` | `null` |
| `newInviteCode` | action | `{ teamId }` | New invite code string |

`createTeam.name` names the team; `memberName` names its creator in the team. On create or join, an omitted member name defaults to the account name, then “Explorer”. Duplicate joins return the existing team ID without changing the member's choices. The eight-member limit includes the creator.

`myTeams` returns:

```ts
Array<{
  teamId: Id<"teams">;
  name: string;
  createdBy: Id<"users">;
  inviteCode: string;
  createdAt: number;
  members: Array<{
    userId: Id<"users">;
    name: string;
    colour: string;
    joinedAt: number;
    isYou: boolean;
    picture: string | null;
  }>;
}>
```

Only fellow members see names and photos. Invite previews intentionally return an empty `memberNames` array. Signed-out callers cannot list teams or preview codes; signed-in outsiders only see teams they belong to.

## Invites and creator controls

Codes contain eight characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`; lookup trims whitespace and ignores case. Actions generate cryptographic candidates and internal mutations pick an unused code transactionally.

Failed previews and all join attempts share a durable limit of 30 per hour per canonical user. Failed joins commit the attempt before the action throws. The counter survives account merging and cannot be bypassed by using a duplicate identity.

Only a creator who is still a member can rename, remove a member or issue a new code. Removing another member rotates the code and records a removal at the current invite epoch. Later removals do not unblock earlier removals. An explicit fresh code advances the invite epoch and allows removed people to rejoin. Leaving removes membership; the last departure also deletes the team and its removal records, in bounded batches when necessary.

The public `/join/<code>` HTTP page never resolves the code or discloses team or member names. It opens `walkies://join/<code>` or shows instructions for a malformed code, and uses `Cache-Control: no-store`.

## Storage and phone sync

`teams` stores name, creator, invite code, creation time and the invite epoch used for removal rules. `teamMembers` stores team ID, user ID, name, colour and join time. `teamRemovals` and `teamInviteAttempts` support invite security. Account merging moves team ownership and memberships; an overlapping membership keeps the canonical member's name, colour and join time.

`TeamsAPI.list()` decodes `myTeams` directly into membership-only `Team` values. The phone stores them together in `teams.json`. A membership revision rejects stale list replies after joining, leaving or editing; signing out invalidates pending refreshes. There are no team uploads, map snapshots, tile cursors, replay jobs or route files, and no shared-map data migration.

## Verification

```sh
npm test -- --configLoader runner
npx tsc -p convex --noEmit
```

Backend tests cover auth, photos, membership changes, invite collisions, rate limiting, removal and rotation, capacity, account merging and the public join page. Swift tests cover the membership wire format and local cache, invite deep links and stale previews, stale membership refreshes, and keeping personal exploration independent of membership.

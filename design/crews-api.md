# Team backend API

Implemented in `convex/crews.ts`; product decisions are in [coop.md](coop.md).
Team contributions are separate from personal walking and progression records.

## Calling conventions

All public functions require a signed-in Convex Auth session. Identity follows
`currentUserId`, including merged accounts. IDs are opaque Convex IDs, not phone
UUIDs. Timestamps are milliseconds since the Unix epoch. `sharing` is `"tiles" |
"tilesAndTrail"`; `walksCount` is a boolean, initially true. Turning walksCount off
instructs the phone to stop queuing contributions, but does not reject offline
uploads or erase existing credits.

Names are trimmed, nonempty and at most 100 characters; colours are nonempty
strings up to 64 characters. Client IDs and secret IDs are at most 200 characters.
Failures throw `ConvexError({ code, message })`.

**Function kinds matter:** use the client's action, mutation or query method as
listed below. Actions wrap transactional writes where crypto randomness or cleanup
after a rejected write is needed. Failed joins commit their attempt counter before
throwing, so transaction rollback cannot bypass the limit. Convex documents these
[runtime boundaries](https://docs.convex.dev/functions/runtimes).

| Function | Kind | Args | Returns |
| --- | --- | --- | --- |
| `createCrew` | action | `{ name, colour, sharing }` | `{ crewId, inviteCode }` |
| `crewForInvite` | mutation | `{ code }` | `{ name, memberNames: [] }` or `null` |
| `joinCrew` | action | `{ code, colour, sharing, name?: string }` | `crewId` |
| `newInviteCode` | action | `{ crewId }` | New invite code string |
| `updateMembership` | mutation | `{ crewId, colour?: string, sharing?: Sharing, walksCount?: boolean }` | `null` |
| `leaveCrew` | mutation | `{ crewId }` | `null` |
| `renameCrew` | mutation | `{ crewId, name }` | `null` |
| `removeMember` | action | `{ crewId, userId }` | `null` |
| `uploadFile` | action | `{ json: string }` | `Id<"_storage">` |
| `addCrewPlace` | action | `{ crewId, clientId, name, file, bounds: { minQ, maxQ, minR, maxR }, gridPlaceId?: Id | null }` | `Id<"crewPlaces">` |
| `uploadCrewTiles` | mutation | `{ crewId, placeId, hexes: [q, r][], at, discoveredAt?: number[] }` | Number of new tiles |
| `uploadCrewTrail` | action | `{ crewId, walkClientId, file, updatedAt }` | `null` |
| `recordCrewSecrets` | mutation | `{ crewId, secrets: { secretId, at }[] }` | `null` |
| `crewSnapshot` | query | `{ crewId, since?: number, cursor?: TileCursor }` | Snapshot below |
| `myCrews` | query | `{}` | `{ crewId, name, memberCount, membership: Member }[]` |

## Invites and memberships

Codes contain eight characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, sampled
with `crypto.getRandomValues` and rejection sampling. An indexed transactional
lookup guarantees uniqueness. Input accepts lowercase and surrounding whitespace.

Each canonical user has a shared hourly allowance of 30 failed invite previews
and join attempts (all joins count). The window begins with the first counted
attempt. Once exhausted, previews and joins return `RATE_LIMITED` until it expires.
Preview results keep the `memberNames` field for compatibility but always return
an empty array. Names of members are available only after joining.

A team holds at most **eight members, including its creator**. A repeated join
returns the team without changing preferences, even when the team is full.
`createCrew` uses the account name; `joinCrew` uses its optional override, then the
account name, then `"Explorer"`.

The original creator must still be a member to rename, remove members or issue an
invite. Removing another member rotates the invite immediately and records their
removal against the current invite epoch. They cannot join using either the old
code or the automatically rotated one. Removing additional members does not
unblock earlier removals. Creator-only `newInviteCode` rotates the code and advances
the epoch, allowing previously removed members to join **with this fresh code**.
It invalidates all earlier codes. Removing a missing member is harmless; removing
yourself is leaving. Ownership does not transfer on departure, but follows an
account merge. A creator who leaves can rejoin if they have a current invite.

Leaving/removal erases route rows and their exclusively owned files. Switching to
`tiles` does the same. New data is capped at 64 trails per member per team, so normal
opt-out/departure cleanup fits in one transaction. Legacy excess drains in batches
of at most 500 rows. Membership identity and a sharing epoch prevent old cleanup
jobs from deleting newly shared routes or old routes from becoming visible after
rejoining/re-enabling. Re-enabling requires a phone replay. Tile/secret credits
survive departure; use fallback labels/colours for departed contributors.

The last departure deletes the team immediately, disabling access and invites.
Place, tile, trail, secret and removal rows then drain in batches of 500 per table.
No other team or personal rows are deleted. Account merges keep one membership per
team. Overlapping memberships retain the canonical user's preferences and discard
the duplicate's routes; other memberships and their routes move to the canonical
user. Attribution moves too, in scheduled batches for large tile histories. Tile
attribution updates advance the ingestion clock so previously synced phones receive
the corrected user IDs in their next delta.

## Files and place grids

1. Prepare dedicated team JSON. Place JSON contains the boundary, streets and grid
   without personal progress. Trail JSON contains only the route inside team places.
2. Call the **`crews:uploadFile({ json })` action**, which accepts valid JSON up to
   2 MiB and returns a storage ID already claimed by the authenticated account.
3. Pass that ID to `addCrewPlace` or `uploadCrewTrail`.

Do not use `sync:generateUploadUrl` for team files. There is no public API to claim
an existing storage ID: only the server's upload action can establish ownership.
Each upload can be consumed by one team row, once. Personal sync rejects claimed
team files as well, so personal and team cleanup cannot delete one another's files.
Unclaimed personal uploads, other users' uploads and already-consumed files are
rejected with `INVALID_UPLOAD` when a write would adopt them.

A retry using the same adopted file is harmless. A fresh unused duplicate is
deleted on an idempotent place retry or an obsolete trail retry. Rejected place or
trail saves discard only the caller's unused claimed file, never a foreign/used
file. Abandoned unused uploads expire after 24 hours. Re-upload if one expires.

All team places must use the first place's grid, including origin and scale. The
phone checks geographic clipping and grid compatibility; the server validates
JSON syntax but does not interpret its geographic contents. `bounds` supplies the
inclusive axial extent of the prepared place grid. All four bounds must be safe
integers with absolute value at most 1,000,000, minima no greater than maxima, and
at most 10,000 coordinate steps along either axis. Every uploaded tile must lie
inside those stored bounds. A team can have at most 16 immutable places and each
place at most 50,000 tiles. These caps also apply if a faulty client supplies
misleading bounds.

The phone supplies `gridPlaceId`: the ID of a downloaded place whose grid it used,
or explicit `null` when building the first place. The save transaction rejects
`GRID_CHANGED` if another first place has appeared or the referenced place no longer
exists. Refresh, rebuild on the shared grid, and re-upload before retrying. This
prevents simultaneous first additions from establishing incompatible grids. The
argument is optional for older clients; those clients cannot guarantee this check.

Adding the same `(crewId, clientId)` returns its original place ID and preserves
its first file, bounds and metadata. There is no place editing/removal API.

Trail `updatedAt` is a required, finite client version for that logical walk. Persist
it with the queued payload and increase it whenever the clipped route changes.
A different file replaces the current route only when its version is strictly
newer. Older/equal versions are ignored and their unused upload discarded. Trail
`at` in snapshots remains server upload time. The 64-trail cap rejects new walk
IDs with `TRAIL_LIMIT`; replacements and retries are allowed. Queue only the walks
the phone intends to share within that cap.

## Contributions and limits

Tile batches accept at most 1,000 safe integer `[q, r]` pairs, including signed
zero (normalized to zero). Duplicates are ignored, even at the place tile cap.
Secrets accept at most 1,000 entries per request, with at most 1,000 stored secrets
per team. Tiles and secrets use **first committed upload wins**, not oldest `at`.
An earlier offline discovery cannot replace another member's existing credit.
Limits and uniqueness are checked transactionally, including concurrent uploads.

Besides the errors above, codes include `UNAUTHENTICATED`, `NOT_A_MEMBER`,
`CREW_NOT_FOUND`, `CREATOR_ONLY`, `INVALID_INVITE`, `INVITE_CODE_EXHAUSTED`,
`MEMBER_REMOVED`, `CREW_FULL`, `INVALID_ARGUMENT`, `PLACE_NOT_FOUND`, `PLACE_LIMIT`,
`PLACE_BOUNDS_REQUIRED`, `TILE_LIMIT`, `TRAIL_LIMIT`, `SECRET_LIMIT`, `FILE_NOT_FOUND`, `GRID_CHANGED`
and `TRAIL_SHARING_DISABLED`. Non-members get `NOT_A_MEMBER` for either missing or
inaccessible teams. Unknown invite previews return null. Refresh membership before
retrying revoked/disabled contributions; do not keep retrying permanent limit errors.

## Snapshot and polling

```ts
type TileCursor = { position: string; until: number; since: number | null };
{
  crew: { crewId, name, createdBy, inviteCode, createdAt },
  members: [{ userId, name, colour, sharing, walksCount, joinedAt, isYou }],
  places: [{ placeId, clientId, name, updatedAt, url: string | null }],
  tiles: [{ placeId, q, r, by: userId, at }],
  trails: [{ walkClientId, url: string | null, by: userId, at }],
  secrets: [{ secretId, by: userId, at }],
  serverTime: number,
  cursor: TileCursor | null,
  more: boolean
}
```

1. Refresh `myCrews` on app open and periodically while open.
2. Start `crewSnapshot({ crewId })` without since for first sync/cache reset, or
   with the last fully applied `serverTime` as `since` for subsequent syncs.
3. Merge each response's tiles. While `more` is true, pass its exact `cursor` and
   the same `since` to the next request. There are at most 1,000 tiles per page.
4. Only after **every page** has been applied, persist the response's `serverTime`
   atomically with the applied changes. Do not advance it after a partial sync.
5. Replace team info, members, places, trails and secrets on each response. Only
   tiles are incremental. Remove team data after losing membership, and hide
   routes when a member disappears or disables sharing.

The first page freezes an upper ingestion watermark for the entire traversal.
The native Convex pagination cursor includes index tie breakers, so a single
`receivedAt` group can span pages without dropping tiles. New uploads made while
paging appear in the next delta. `receivedAt` is a monotonic server clock persisted
in the team, advancing strictly on new tiles; phone discovery times do not affect
pagination. Treat `serverTime` and the cursor as opaque. Complete metadata is
bounded by the caps above; tiles retain the existing object format, with pages
small enough to avoid a packed-array API change. URLs can be null.

## Public invite page

`GET https://<deployment>.convex.site/join/<code>` always returns HTTP 200, with
`Cache-Control: no-store`. It never looks up a team or reveals team/member names.
Every well-formed code, real or unknown, gets the same generic page with its
`walkies://join/<CODE>` button and automatic open attempt. Malformed links get
generic guidance. Public requests cannot test invite existence; authenticated,
rate-limited calls resolve the invite inside the app.

## Existing data and deployment

This change does not deploy or migrate a live database. New schema fields are
optional so existing records remain readable. Before deploying against existing
team data, rotate any six-character codes, backfill verified place bounds and
accurate tile counts, and audit file ownership. Places without bounds/counts
reject new tile writes with `PLACE_BOUNDS_REQUIRED`. Unclaimed legacy team files
are deliberately retained during row deletion because their exclusive ownership
cannot be established safely; an audited migration must clean them up. Existing
rows beyond the new metadata caps also need an audit before rollout.

## Local verification

`convex/crews.test.ts` uses `convex-test`, real users, identities and storage in the
edge runtime. It covers each review finding, paging across equal ingestion times,
merges, cleanup and retries.

```sh
npm test
npx tsc -p convex --noEmit
```

In a restricted checkout with `node_modules` symlinked outside the writable tree,
use `npm test -- --configLoader runner` to avoid Vite's temporary config write in
that shared directory. Tests and typechecking do not deploy anything.

`uploadCrewTiles` also accepts optional `discoveredAt: number[]`, one finite millisecond timestamp per `hexes` entry. Older clients can keep using the batch-wide `at`. The phone packs history replay into at most 400 tiles per place per batch, retaining exact first-discovery dates through `discoveredAt`.

Paused members (`walksCount: false`) receive `CONTRIBUTIONS_PAUSED` from tile, secret and trail contribution endpoints. Existing shared data stays available. The phone clears unsent contribution queues on pause and excludes locally paused walks from future replay.

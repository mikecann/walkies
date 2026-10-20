# Crew backend API

Implemented in `convex/crews.ts`; product decisions are in [coop.md](coop.md).
This is the backend contract for the next iPhone implementation. These functions
never write personal walks, places, secrets or the progression ledger.

## Calling conventions

- Call public functions as `crews:<function>` with a signed-in Convex Auth session.
  Identity comes from `currentUserId`, including its canonical merged account.
- IDs are opaque Convex IDs. `crewId`, `placeId` and member `userId` are server
  IDs, not phone UUIDs. Keep a place's `clientId` to correlate it with the phone.
- All timestamps are milliseconds since the Unix epoch. `at` on tiles/secrets
  is the phone's discovery time; `at` on trails is the server upload time because
  the trail API has no discovery-time argument.
- `sharing` is `"tiles" | "tilesAndTrail"`. `walksCount` is a **boolean**, initially
  true. It tells the phone whether to queue contributions for this crew. Changing
  it does not erase history or reject uploads already queued offline.
- Names are trimmed, nonempty and at most 100 characters. Colours are opaque,
  nonempty strings up to 64 characters (the phone should use its colour format).
  Client IDs and secret IDs are trimmed, nonempty and at most 200 characters.
- Failures throw `ConvexError({ code, message })`. Codes are `UNAUTHENTICATED`,
  `NOT_A_MEMBER`, `CREW_NOT_FOUND`, `CREATOR_ONLY`, `INVALID_INVITE`,
  `INVITE_CODE_EXHAUSTED`, `INVALID_ARGUMENT`, `PLACE_NOT_FOUND`,
  `FILE_NOT_FOUND`, and `TRAIL_SHARING_DISABLED`. Non-members get `NOT_A_MEMBER`
  for either missing or inaccessible crews. An unknown invite preview returns null.

## Functions

| Function | Args | Returns |
| --- | --- | --- |
| `createCrew` | `{ name, colour, sharing }` | `{ crewId, inviteCode }` |
| `crewForInvite` | `{ code }` | `{ name, memberNames: string[] }` or `null` |
| `joinCrew` | `{ code, colour, sharing, name?: string }` | `crewId` |
| `updateMembership` | `{ crewId, colour?: string, sharing?: Sharing, walksCount?: boolean }` | `null` |
| `leaveCrew` | `{ crewId }` | `null` |
| `renameCrew` | `{ crewId, name }` | `null` |
| `removeMember` | `{ crewId, userId }` | `null` |
| `addCrewPlace` | `{ crewId, clientId, name, file: Id<"_storage"> }` | `placeId: Id<"crewPlaces">` |
| `uploadCrewTiles` | `{ crewId, placeId, hexes: [q, r][], at }` | Number of newly inserted tiles |
| `uploadCrewTrail` | `{ crewId, walkClientId, file: Id<"_storage"> }` | `null` |
| `recordCrewSecrets` | `{ crewId, secrets: { secretId, at }[] }` | `null` |
| `crewSnapshot` | `{ crewId, since?: number }` | Snapshot below |
| `myCrews` | `{}` | `{ crewId, name, memberCount, membership: Member }[]` |

`createCrew` uses the account name for the first membership; `joinCrew` uses its
optional name override, then the account name, then `"Explorer"`. Repeated joins
return the same crew without changing any existing preferences. Invite codes are
six characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, unique by indexed
transactional lookup, and accepted case-insensitively with surrounding whitespace.

`renameCrew` and `removeMember` require the original creator to still be a member.
Removing a missing member is harmless; removing yourself is leaving. Creator
ownership does not transfer when they leave. They can rejoin using the invite to
manage the crew again. There is no ownership transfer API in this stage.

Leaving or removal deletes the membership, route rows and their stored files.
Switching to `tiles` does the same for routes. Re-enabling trail sharing does not
restore them; the phone must replay them. Tile and secret credits survive departed
members. The snapshot returns historical credits as user IDs even if that user is
no longer in its members list; the phone needs a fallback label/colour for those.
The last departure deletes the crew and invalidates the invite immediately. It
also deletes places, tiles, trails and secrets, including its place/route files.
Large maps continue deleting inaccessible rows through the internal
`cleanupEmptyCrew({ crewId }) -> null` scheduled mutation in batches of 500 per
table. Small crews are cleaned up in the departure transaction. Other crews and
personal records remain separate.

## Files and place grids

1. Call the existing `sync:generateUploadUrl({})` mutation.
2. POST the prepared JSON to that URL and keep the returned `storageId`.
3. Pass that ID as `file` to `addCrewPlace` or `uploadCrewTrail`.

Upload a **dedicated file for each crew place or crew walk**, rather than reusing
a personal sync file or another row's storage ID. The backend deletes owned
route/place files when replacing or removing their rows. Retrying the same trail
with the same file ID is harmless and does not delete that file.

The phone prepares and validates JSON contents. A crew place contains its boundary,
streets and hex grid, without personal visited tiles. All places in a crew must
use the **first crew place's grid**, including origin and scale. Fetch the snapshot
before building another place; do not use a nearby personal grid independently.
The backend checks that the uploaded storage object exists, but does not parse its
JSON or verify geographic clipping/grid compatibility.

A place is immutable in this version. Adding the same `(crewId, clientId)` again
returns its original `placeId`, preserving the first file and metadata. Save that
result and then replay past walks onto it. Prefer retrying the same uploaded file;
a newly uploaded unused duplicate is not adopted or deleted by this function.
There is no place editing/removal API in this stage.

Trail JSON must contain **only the route portions inside the crew's places**.
Never submit the personal walk file or raw journey to/from the place. The server
requires `tilesAndTrail`, stores one file per `(crewId, caller, walkClientId)`, and
replaces/deletes its previous file on a new upload. Trails are not live locations.

## Uploads and first discovery

`uploadCrewTiles` accepts up to 1,000 hex pairs per call; batches of a few hundred
fit comfortably. Coordinates must be safe integers. Empty batches return zero.
`placeId` must belong to this crew. Duplicate pairs, including signed zero, are
ignored. Tiles are unique per crew + place + q + r, so overlapping place coverage
still has separate place records, using the common grid.

`recordCrewSecrets` accepts up to 1,000 entries per call. Both tiles and secrets use
**first committed upload wins**, not the oldest `at`. An earlier offline walk
uploaded later cannot overwrite another member's existing credit. These mutations
are safe to retry. Upload retry queues should stop retrying revoked memberships
or disabled trail sharing until the phone has refreshed the user's settings.

## Snapshot and polling

```ts
{
  crew: { crewId, name, createdBy, inviteCode, createdAt },
  members: [{ userId, name, colour, sharing, walksCount, joinedAt, isYou }],
  places: [{ placeId, clientId, name, updatedAt, url: string | null }],
  tiles: [{ placeId, q, r, by: userId, at }],
  trails: [{ walkClientId, url: string | null, by: userId, at }],
  secrets: [{ secretId, by: userId, at }],
  serverTime: number
}
```

1. Fetch `myCrews` on app open and periodically while open to refresh memberships.
2. Fetch each `crewSnapshot({ crewId })` without `since` on first sync or cache reset.
3. Persist its `serverTime` **with the applied tile changes**, per crew.
4. Next time, pass that saved value as `since` and merge the returned tiles.
5. **Replace** crew info, members, places, trails and secrets on every response.
   Only the tiles array is incremental. Replacing routes is necessary to honour
   opt-outs, replacements and departures. Remove local crew data after losing
   membership; stop displaying routes when a member disappears or stops sharing.

`serverTime` is a persisted, server-assigned **tile cursor**, initialized to crew
creation time. It advances only when new tiles are committed, to at least the
current wall time and strictly above its previous value. It may be slightly ahead
of wall time for uploads in the same millisecond, and may stay unchanged during
idle polls. Treat it as opaque: never substitute the phone's clock or request time.
`since` filters by a tile's server ingestion cursor (`receivedAt > since`), not its
old discovery time. This makes historical walk replays and same-millisecond polls
safe without dropping tiles. Metadata, secrets and routes always remain complete.
URLs may be null if a stored object is unavailable; don't treat null as a URL.

## Invite landing page

`GET https://<deployment>.convex.site/join/<code>` returns a small cream HTML page
with the crew name, an `Open Walkies` button to `walkies://join/<CODE>` and an
immediate attempt to open that URL. Names are HTML-escaped. Unknown/malformed
codes return a friendly 404 page. Pages use `Cache-Control: no-store`.

The landing page is deliberately public and resolves only the crew name and code
through the internal `inviteForPage` query. The app's richer `crewForInvite` query
requires sign-in and returns member names for the join screen. The iOS deep-link
handler and phone sync are the next stage, not part of this backend change.

## Local verification

Following the [Convex testing workflow](https://docs.convex.dev/testing/convex-test),
`convex/crews.test.ts` uses `convex-test` with real user rows and `withIdentity`.
OAuth components do not need registration for these tests: Convex Auth v2's user
helper reads the identity subject and `currentUserId` resolves the merged user.

```sh
npm install
npx tsc -p convex --noEmit
npm test
```

Vitest runs in the edge runtime. Tests are never deployed or imported by the app.

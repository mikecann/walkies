# Co-op: team maps

Mike wants a shared map he and his dad fill in together by walking, alongside his own. Decided with Mike on 2026-10-20.

## The idea

- **My map** is what Walkies has today: your places, your clouds, your secrets. Nothing about it changes.
- A **team map** is a separate map shared by a few people (Mike and his dad, to start). It has its own places, its own clouds and its own secrets book. A tile is uncovered on it when any member walks it.
- **Every walk counts everywhere.** One walk uncovers tiles on My map and on every team map you're in, if that team map has a place there. No switching before you head out (Always on makes that essential). Each team map has a "My walks count here" switch, on by default, if you ever want one to only count walks you do together.
- **Shells and levels stay personal**, worked out from My map as now, so co-op can't be farmed and a team map never changes your shells.

## Joining and sharing

- Anyone signed in can **start a team map**: name it ("Mike & Dad"), pick a colour for themselves, and share an invite link (`https://<site>/join/<code>`, which opens Walkies at `walkies://join/<code>`; an eight-character code can be typed in too).
- Joining asks what to share, and you can change it any time in that team map's settings:
  - **Tiles only**: the team sees which tiles you've uncovered, never where you walked.
  - **Tiles and trail**: the team also sees your routes, but only the parts inside the team map's places, so the route to and from your house outside them is never shared.
- **Your past walks count** when you join, or when a place is added to the team map: your phone replays the walks you've already done in that place onto the team map. Only the resulting tiles (and trail, if you share it) are sent.
- Teams hold up to eight members. Members can leave. A team map with nobody left is deleted. The person who started it can remove members, rename it and issue a fresh invite. Removing someone rotates the code and keeps them out until the creator explicitly issues a fresh invite.

## What the team map shows

- The usual clouds, with tiles cleared by anyone. In the drag honeycomb, tiles are tinted with the colour of whoever uncovered them first.
- Members who share their trail have their routes drawn in their colour.
- The place chip says which map you're on; tapping it lets you switch between My map and your team maps, start one, or join one.
- The secrets book for a team map shows secrets found by anyone, with "Found by Dad · 21 Oct". Personal secrets unlock only when you cross their placement on My map. Team finds stay in the team book and never award personal secrets, shells or levels.
- The end-of-walk celebration adds a line per team map: "+12 tiles for Mike & Dad".
- Neighbouring suburbs' "+" buttons add the suburb to whichever map you're looking at.

## Data

See the [team API contract](teams-api.md).

Convex, alongside the existing per-user tables:

- `teams`: name, createdBy, inviteCode, createdAt.
- `teamMembers`: teamId, userId, name, colour, sharing (`tiles` or `tilesAndTrail`), walksCount, joinedAt.
- `teamPlaces`: teamId, clientId, name, the place file (boundary, streets and its hex grid, without anyone's visited tiles), addedBy, updatedAt.
- `teamTiles`: teamId, placeId, q, r, by (userId), at. One row per tile, first uncoverer wins.
- `teamTrails`: teamId, userId, walkClientId, file (the route, clipped to the team places), at. Deleted if the member switches to tiles only or leaves.
- `teamSecrets`: teamId, secretId, by, at. First finder wins.

Every function checks the caller is a member, using `currentUserId`. A team map's places all share one hex grid (the first place's), so tiles line up between members' phones. Phones fetch team maps when the app opens and every few minutes while it's open, and upload new team tiles, trails and secrets with the rest of sync. The phone stays the source of truth for its own walking: team uploads are queued and retried like the rest.

## Not in the first version

- Live dots of each other while walking.
- A competitive mode (racing to 100%).

Pausing contributions clears unsent tiles, secrets and routes. Places received while paused are marked replayed. Walks paused on this phone (including a walk spanning the pause) are excluded from later history replay; resuming does not backfill them.

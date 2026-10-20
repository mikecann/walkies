# Teams

Teams are membership only. Mike changed direction on 2026-10-20: revealing the map yourself is the fun. Teammates must never clear your clouds or open your secrets.

## What teams do now

- Signed-in walkers can start a team, choose their name and colour, and invite someone by an eight-character code or link.
- The invite page at `https://<site>/join/<code>` opens `walkies://join/<code>`. You can also type the code in Walkies.
- A team holds up to eight members. Members see each other's names, colours and Google photos, with initials when there is no photo.
- Members can change their own name and colour or leave. The creator can rename the team, remove someone and issue a fresh invite code. Removal rotates the current code and blocks rejoining until the creator explicitly issues a fresh one. The last departure deletes the team.
- Membership is cached in one `teams.json` file and refreshed by sync. Account merging retains membership and team ownership.

## The place chip

The closed chip shows your own head, the place name, your explored percentage and a chevron.

Opening it shows your progress bar, tiles explored and secrets found, followed by a small Team section. Each team has its members' heads and name; tapping it opens settings with members, the invite card, your name and colour, creator controls and Leave. Start a team and Join with a code remain available, including when you have no team. Change place comes last and opens the personal place list.

Start and Join say: “Your team can see each other here. Your clouds and secrets stay yours.”

## Removed

There are no shared places, tiles, trails, secrets or uploads. There is one map, containing your own places and progress. Walking, past-walk replay for newly added personal places, secret discovery, shells, levels and celebrations all belong to you.

The previous shared-map state, server tables, snapshot and upload APIs, background replay jobs, team upload queues, per-team files, sharing choices and contribution pause rules have been deleted. There is no migration of shared-map data. Existing development data is disposable; the upcoming world-grid change will reset data separately. Personal grid behaviour is unchanged apart from removing the team-only explicit grid override.

## Later ideas, not implemented

Membership leaves room for a different team feel: a coloured overlay of a teammate's tiles without clearing your clouds, “Dad found a secret” notifications, shared goals, or jigsaw secrets that need several teammates. None of those features is part of this change.

# Progression model API

This stage adds no screens or map styling. `AppModel` owns the local ledger and
schedules sync after successful actions. All the maths in `Progression.swift` is
`nonisolated` and accepts an explicit date and calendar for tests.

## Reading from AppModel

| API | Meaning |
| --- | --- |
| `progression` | Cached `Progression.State`, independent of spending. |
| `earnedBreakdown` | Lifetime shells from tiles, secrets, milestones, streaks and quests. `total` is their sum. |
| `balance` | Earned shells plus claimed shell bags, less purchases. |
| `xp`, `level` | Walking XP and its level, starting at level 1. |
| `nextLevelXP`, `xpToNextLevel` | Next total XP threshold, and the remaining XP. |
| `pendingPicks` | Unclaimed level numbers, oldest first. Level 1 has no pick. |
| `picks(for:)` | Three choice strings for that level. Pass a string back to `claim`. |
| `weeklyQuests` | This Monday-to-Sunday week's three `Quest` values: kind, name, progress, target, completion and reward. |
| `owned`, `equipped` | Owned cosmetic IDs, and the equipped ID for each group (`equipped[group]`). |
| `spyglasses` | Purchased/claimed spyglasses less all recorded uses. |
| `activeSpyglassRing` | Selected place's active ring, or nil. Centre is a `Coordinate`, radius is metres, expiry is a `Date`. |
| `ledger` | Read-only persisted ledger, available for inspection. |

The state cache invalidates with tile revisions, walk count, secret revisions and
the local calendar day/time zone. Legacy per-place route analysis is cached
separately across GPS fixes, until a walk or counting grid changes. Use a clock-driven view refresh for the weekly
rollover and ring expiry. Reading `activeSpyglassRing` checks the current time;
there is no model timer.

## Actions

All return `Bool`: true means applied and saved, false means the action isn't
currently available. Success requests sync through the existing callback.

```swift
model.buy("trail.sparkles")          // Requires balance; buys and equips.
model.equip("marker.dot")            // Requires ownership; cosmetics only.
let level = model.pendingPicks.first!
let choices = model.picks(for: level)
model.claim(level: level, choice: choices[0])
model.useSpyglass()                  // Requires a spare and an unfound secret here.
```

An already active ring in the selected place blocks another use. A ring expires
exactly three hours after use, or immediately when its secret is found. Uses stay
in the ledger after expiry, so they cannot be spent again.

## Catalog and reward choices

`Progression.catalog` contains `Item`s with `id`, `name`, optional `group`, `price`
and `isFree`. `Progression.Group.allCases` lists the five cosmetic groups. A nil
group is the consumable `spyglass` (60 shells).

A level choice is a catalog cosmetic ID, `Progression.shellBag` (`shells.50`) or
`Progression.spyglassPair` (`spyglasses.2`). The last two mean 50 shells and two
spyglasses. The price ceiling starts at 150 at level 2 and rises by 50 each level.
Candidates are seeded by level, prefer unowned cosmetics, then fall back to the
bag and spyglass pair. Once all cosmetics are owned there are only two distinct
reward types, so the third slot repeats the bag. Render choice slots by index,
not by choice string.

`Ledger.offers` is optional, backwards-compatible metadata beyond the four fields
in the original design. It freezes each three-choice menu when a level is first
reached, so buying something later cannot change that menu. Offers merge by
level, first wins, just like claims. If a cosmetic in a frozen menu has since
been acquired, selecting it credits a 50-shell bag instead. Both phones accept
the server's first claim/offer when resolving competing offline choices.

Shell bags add spending money, not XP. XP is exactly the five-source earned
total, so a pick cannot generate another level by itself. Buying never alters XP,
tiles, secrets or quest progress. Offline purchases and uses are never discarded
on merge: conflicting spending can leave a negative balance or consumable count,
and further spending is blocked until enough has been earned/bought.

## Pure functions and recap

- `Progression.state(Inputs)` computes earned sources, level and current quests.
- `xp(for:)`, `level(for:)`, `pendingLevels(xp:ledger:)` expose the level curve.
- `week(containing:calendar:)`, `questKinds(for:)`, `quests(for:inputs:)` and
  `questProgress(_:week:inputs:)` expose deterministic weekly quests.
- `picks(for:owned:)` generates a menu; `Ledger.preparePicks(xp:)` freezes it and
  `Ledger.picks(for:)` reads the frozen menu.
- `walkEarnings(before:after:)` gives a `WalkEarnings` with shell/XP deltas,
  source breakdown and increased quest progress. `QuestGain` includes week,
  kind, before/after values, target, gained amount and newly completed status.
- `spyglass(in:from:found:now:id:)` chooses the nearest unfound secret and creates
  a use record without spending it. `activeRing(in:ledger:found:now:)` reads it.
- `Ledger.merged(with:)` unions purchases/uses by ID, claims/offers by level,
  and takes the later equipped timestamp. Equal timestamps keep the receiver.
- `Ledger.balance(earned:)`, `owned`, `spent`, `rewardShells` and
  `spyglassesLeft` expose the spending calculations.

`WalkRecap.earnings` is computed once by `make`, from before/after coverage and
history. `shells`, `xp` and `questProgress` are convenience accessors for the
celebration. It includes all places for milestone totals, even though the
existing recap's map arrays only contain touched places.

## Calendar and history choices

Weeks use the phone calendar/time zone, forced to Monday with the four-day first
week rule. Seeds use week-year and week number, including around New Year.
Finished walks belong to the week and day they started in; secret discoveries
use their own dates. Any finished walk counts for quest days/distance. The
300-metre minimum applies only to streak rewards, as specified in the design.
Streaks use calendar-day arithmetic, including daylight-saving changes, and
only award once per date. Historical completed quests remain in lifetime XP.

The other-place quest compares against the place with most counting tiles at
the **start of that week**, so walking elsewhere cannot undo completion by
changing the favourite. Ties use the place UUID. Future walks save optional
`Walk.newTilesByPlace` counts (UUID strings as keys); older walks recover counts
by replaying accepted route samples in chronological order over today's tiles.
As with the design's other derived earnings, deleting a place or changing its
counting tiles can change historical totals.

## Persistence and sync

`Store.loadProgress()` and `save(progress:)` read/write `progress.json`. The
existing whole-directory sign-out wipe removes it. Ledger timestamps are Unix
**seconds** as numbers in both languages, rather than Swift's default Date epoch.

`sync:saveProgress({ ledger: String })` authenticates through `currentUserId`,
merges with the existing `progress` row and returns null. `sync:snapshot` adds
`progress: String | null`. The iPhone pushes only when canonical ledger JSON
changes, then merges the snapshot with server precedence. Duplicate-account
migration also merges the progress rows.

An equipped cosmetic from a losing offline claim falls back to its group's free
default in `AppModel.equipped`; the original last-write record stays in the ledger
for correct sync.

Local tests without CoreSimulator:

```sh
scripts/test-progression-model.sh
node scripts/test-progression-sync.mjs
npx tsc -p convex --noEmit
```

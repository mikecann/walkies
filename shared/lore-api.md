# Secrets for new suburbs: what the apps get

The server researches and writes secrets for a suburb once someone has added it and walked in it, which it checks for itself (`convex/lore.ts`). This is what the iPhone and Android apps download them with (`Walkies/Model/ServerLore.swift`, `ServerLore.kt`, and `updateLore` in each `AppModel`). The apps keep their own copy of `bundledOsmIds` in `Walkies/Lore/bundled-places.json`, so bundled places never ask; `convex/lore.test.ts` checks the two match.

## `lore:forPlace`

A public query. It needs a signed-in user, like `places:get`.

```
lore:forPlace({ osmId: number }) -> { status, version, entries }
```

`osmId` is the place's OpenStreetMap relation, `City.osmId`. A place without one has no server secrets.

| `status` | What it means | What the app does |
|---|---|---|
| `bundled` | The app ships its own secrets for this place (the Busselton area, `bundledOsmIds` in `convex/loreConfig.ts`). | Use the bundled ones. Don't ask again. |
| `none` | Nobody has walked here since the server started researching. | Nothing yet. Ask again after the next walk there syncs. |
| `queued` | Waiting for a free slot or for a spending cap to reset. It can take until the next day. | Show the "researching your area" card. |
| `researching` | A run is going. It takes 5 to 15 minutes. | Show the card, and ask again every couple of minutes while the app's open. |
| `ready` | Done. | Use `entries`. |
| `quiet` | Done, but there wasn't much to find (fewer than three secrets). Whatever was found is in `entries`. The server has one more look after 90 days. | Use `entries`, with friendly copy about a quiet suburb. |
| `failed` | The run broke. The server retries once after a day. | Treat it like `none`. |

The server keeps more detail than these seven words: a quiet or failed place waiting for its next look, and a place a walk queued that waited 30 days without starting, which is as if nobody had walked there. `lore:forPlace` reports those as `quiet`, `failed` and `none`, so the apps never see a word they don't know. The whole lifecycle is in [docs/machines.md](../docs/machines.md).

`version` goes up whenever the live secrets change: a run finishing, Mike approving one, or Mike hiding one. Cache the answer and the sticker PNGs in Application Support, and only fetch the stickers again when `version` changes. A secret can disappear from `entries` (hidden later), so replace the cached list rather than merging it.

Only live secrets come back. Ones waiting for Mike's review, hidden ones, and ones the checks dropped never do.

## An entry

Each entry is the same JSON as a `LoreEntry` in `Walkies/Lore/*.json` (`Walkies/Model/Lore.swift`, `Lore.kt` on Android), plus `stickerUrl`, so the existing decoders read it:

```json
{
  "id": "osm11688696-the-seagrass-that-moved-house",
  "title": "The Seagrass That Moved House",
  "body": "45 to 95 words of the story.",
  "category": "the-sea",
  "place": { "name": "Western Beach, Port Geographe", "lat": -33.632, "lon": 115.3865 },
  "sticker": "A grumpy brown mountain of seagrass with little wavy stink lines rising off the top",
  "sources": ["https://www.abc.net.au/news/..."],
  "suburb": "Geographe",
  "stickerUrl": "https://<deployment>.convex.cloud/api/storage/<id>"
}
```

- `id` always starts with `osm<relation>-`, so it never clashes with a bundled secret's id. Found secrets sync with `sync:saveSecrets` the same way as bundled ones.
- `category` is one of `history`, `first-nations`, `nature`, `the-sea`, `odd-records` or `modern-life`.
- `place` is missing when the story is about the whole suburb. Those get scattered over its streets, the same as bundled ones without a pin. When it's there, it's already been moved onto the nearest walkable street inside the suburb, so `placeStickers()` will find a street tile for it.
- `suburb` is the place's OpenStreetMap name. Assign server entries to a city by `City.osmId`, not by matching this.
- `photos` is never set.
- `sticker` is what the art shows. The art itself is at `stickerUrl`: a 512 × 512 PNG on a transparent background, the same as the bundled `sticker-<id>` assets. It's `null` if the drawing failed or the run couldn't afford it, so show a plain placeholder sticker. Art drawn later bumps `version`, like any other change.

## Mike's review in the app

Public, but only for Chef's admin (the `admin` role in the feedback component, the same one `chef:amAdmin` checks). The iPhone shows them in Settings under "Secrets waiting for you".

| Function | What it does |
|---|---|
| `lore:adminPending` (query) | The secrets waiting for review, the same as `lore:pending` (which now says each one's `suburb` too). `null` for anyone else, so the app hides the list. |
| `lore:adminApprove({ entryId })` (mutation) | `lore:approve`. Throws for anyone else. |
| `lore:adminHide({ entryId })` (mutation) | `lore:hide`. Throws for anyone else. |

Approving or hiding one bumps the place's `version`, so phones pick the change up the next time they ask.

The iPhone only asks while it might be the admin: once `lore:adminPending` has answered `null` for the signed-in account, Settings doesn't ask again for a week.

## Running it by hand

All of these are internal, so only `npx convex run` (or the dashboard) can call them. Add `--prod` for production.

| Command | What it does |
|---|---|
| `npx convex run lore:status` | Every researched place, what it cost, and today's and this month's spend |
| `npx convex run lore:credits` | What the OpenRouter key has used and has left, from OpenRouter (its limit is the backstop behind the caps) |
| `npx convex run lore:research '{"osmId": 123}'` | Researches a place now, ignoring the switch and the walked check but not the caps |
| `npx convex run lore:entries '{"osmId": 123}'` | Every secret a place's runs wrote, dropped ones too, with what each check said |
| `npx convex run lore:pending` | Secrets waiting for review |
| `npx convex run lore:approve '{"entryId": "osm123-..."}'` | Puts one live |
| `npx convex run lore:hide '{"entryId": "osm123-..."}'` | Takes one down, and deletes its sticker art |
| `npx convex run lore:resume '{"osmId": 123, "from": "lorePipeline:write"}'` | Runs a finished run again from one of its steps, keeping what the earlier steps found and paid for (see below). `from` is required |
| `npx convex run lore:readPage '{"url": "https://..."}'` | Reads a page the way the pipeline does, or says why it won't |
| `npx convex run lore:machines` | How many places and secrets are in each state, and any timers whose step failed |
| `npx convex run lore:history '{"osmId": 123}'` | A place's research step by step: every event, who sent it, and where it went |
| `npx convex run machines:failedTimers` | Timers (a retry, the queue's expiry) whose step threw. They stay pending until `machines:rearmTimer` |

### Resuming a run

`lore:resume` queues the run like a new one: it waits for a free slot and for the daily and monthly caps the same way, and then restarts the run's journal from the step `from` names. Step names, in order, are `lorePipeline:prepare`, `research heritage` (and `research nature`, `research stories`), `loreRun:checkBudget`, `lorePipeline:write`, `lorePipeline:checkQuotes`, `lorePipeline:factCheck`, `loreRun:applyRules`, `lorePipeline:checkPins`, `stickers`, `sticker osm123-<slug>` and `loreRun:publish`; a name that isn't in the journal is an error straight away.

- **Budget.** A resume is a new budget segment: it gets its own `caps.perRun` ($6), and `runCost` starts again from 0. What the run spent before still counts towards the day and the month (`cost` keeps the total), so a resume can never take those past their caps.
- **Drafts.** Writing again (resuming from `lorePipeline:write` or earlier) replaces the run's own unfinished drafts instead of adding to them. A draft for a story that's already out, from this run or any other, is skipped, so nothing live is duplicated.
- **What comes back.** Secrets dropped as `run stopped`, `budget` or `not checked` (the run's fault, not theirs) go back into the running. Nothing is published without passing the fact-check, so one that comes back is only published if a fact-check step runs again or it had already passed.
- **Stickers later.** A run that runs out of money at the stickers still publishes what passed; those secrets have `stickerUrl: null` until `"from": "stickers"` draws the missing ones.
- **How long.** A run's journal is kept for 14 days after it finishes, or until the place's next run starts; after that the run can't be resumed, and `lore:research` starts a new one. Its research threads (every page the agents read) are deleted as soon as it finishes.

### Spending

Every paid OpenRouter call books a hold before it's sent: the most it could cost, from its prompt size, its `max_tokens` and the prices in `convex/loreConfig.ts`. A call is refused if its hold could take the run's segment past $6, the UTC day past $15 or the month past $50. After the call the hold is settled to OpenRouter's `usage.cost`. A call that never answers, can't be read, or has no `usage.cost` keeps its whole hold as spent (`unpriced` in `loreSpend`); a hold still open after an hour is kept the same way. `lore:status` counts holds in today's and this month's totals.

Walks only start research when the deployment's `LORE_AUTO` environment variable is exactly `1`; with anything else, only `lore:research` and `lore:resume` start runs, and a quiet or failed place's next look waits a day at a time until it's on. A walk only starts one when the server agrees: the relation is an admin boundary between 0.1 and 400 km², one of the person's own saved walks has at least three good GPS fixes inside it, and they haven't started three suburbs today or six this month. A place a walk queued that hasn't started after 30 days leaves the queue.
